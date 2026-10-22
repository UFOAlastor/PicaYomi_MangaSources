#!/usr/bin/env python3
"""Build immutable source packages and optional signed subscription catalogs."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def read_unique(pairs):
    result = {}
    for k, v in pairs:
        if k in result:
            raise ValueError(f"duplicate JSON key: {k}")
        result[k] = v
    return result


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sign(key_path, purpose, raw):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    key = serialization.load_pem_private_key(Path(key_path).read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("an Ed25519 PEM key is required")
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    return public, key.sign(b"PicaYomi/" + purpose.encode() + b"/v1\0" + raw).hex()


def atomic(path, raw, immutable=False):
    if path.exists() and immutable:
        if path.read_bytes() != raw:
            raise ValueError(f"immutable release already exists with different bytes: {path.name}")
        return
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_bytes(raw)
    temp.replace(path)


def prune_packages(output):
    """Keep the latest local package per ID and every catalog-referenced release."""
    output = Path(output)
    protected = set()
    index_path = output / "index.json"
    if index_path.exists():
        index = json.loads(index_path.read_text(), object_pairs_hook=read_unique)
        if index.get("signed") == 1:
            index = json.loads(index["payload"], object_pairs_hook=read_unique)
        for entry in index["sources"]:
            protected.add(f'{entry["id"]}-{entry["version"]}.pysource')
    groups = {}
    for path in output.glob("*.pysource"):
        match = re.fullmatch(r"([a-z][a-z0-9_-]*)-(\d+)\.(\d+)\.(\d+)\.pysource", path.name)
        if not match or path.is_symlink() or not path.is_file():
            continue
        try:
            manifest = json.loads(path.read_text(), object_pairs_hook=read_unique)["manifest"]
            if manifest["id"] != match[1] or manifest["version"] != ".".join(match.groups()[1:]):
                continue
        except (ValueError, KeyError, TypeError, UnicodeError):
            continue
        groups.setdefault(match[1], []).append((tuple(map(int, match.groups()[1:])), path))
    removed = []
    for releases in groups.values():
        newest = max(releases, key=lambda item: item[0])[1]
        for _, path in releases:
            if path != newest and path.name not in protected:
                path.unlink()
                removed.append(str(path))
    return removed


def build(source, output, base_url=None, name="PicaYomi Sources", notes="", sign_key=None, revision=None, rotation_key=None):
    source, output = Path(source), Path(output)
    manifest = json.loads((source / "manifest.json").read_text(), object_pairs_hook=read_unique)
    project_dist = Path(__file__).resolve().parents[1] / "dist"
    if manifest.get("id") == "example" and (output.resolve() == project_dist or project_dist in output.resolve().parents):
        raise ValueError("example is a test fixture; build it into a temporary directory, not dist")
    for key in ("id", "name", "author", "version", "api_version", "min_app_version", "entry"):
        if key not in manifest:
            raise ValueError(f"missing manifest field: {key}")
    if not isinstance(manifest["id"], str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,79}", manifest["id"]):
        raise ValueError("invalid source id")
    for key, limit in (("name", 160), ("author", 200)):
        if not isinstance(manifest[key], str) or not 0 < len(manifest[key].encode()) <= limit:
            raise ValueError(f"invalid manifest field: {key}")
    for key in ("version", "min_app_version", "max_app_version"):
        if key in manifest and (not isinstance(manifest[key], str) or len(manifest[key]) > 32 or not re.fullmatch(r"\d+\.\d+\.\d+", manifest[key])):
            raise ValueError(f"invalid version: {key}")
    if isinstance(manifest["api_version"], bool) or manifest["api_version"] not in (1, 2, 3):
        raise ValueError("unsupported source API")
    if manifest["api_version"] >= 2 and not re.fullmatch(r"[\w.-]{1,100}", manifest.get("publisher_id", ""), flags=re.ASCII):
        raise ValueError("API v2/v3 requires publisher_id")
    if manifest["api_version"] == 3 and tuple(map(int, manifest["min_app_version"].split("."))) < (0, 10, 6):
        raise ValueError("API v3 requires min_app_version >= 0.10.6")
    if manifest.get("identity_policy") == "legacy" and manifest["id"] not in {"picacg", "jm", "htcomic"}:
        raise ValueError("legacy identity is reserved for migrated sources")
    if manifest.get("identity_policy") not in (None, "stable", "legacy"):
        raise ValueError("invalid identity policy")
    for key in ("data_schema_version", "cache_schema_version"):
        if key in manifest and (type(manifest[key]) is not int or manifest[key] < 1):
            raise ValueError(f"invalid schema version: {key}")
    if "max_app_version" in manifest and tuple(map(int, manifest["max_app_version"].split("."))) < tuple(map(int, manifest["min_app_version"].split("."))):
        raise ValueError("maximum host version is below minimum")
    if not isinstance(manifest["entry"], str):
        raise ValueError("invalid entry")
    settings = manifest.get("settings", [])
    if not isinstance(settings, list) or len(settings) > 16:
        raise ValueError("invalid source settings")
    seen_keys = set()
    for field in settings:
        if (not isinstance(field, dict) or not isinstance(field.get("key"), str)
                or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", field["key"])
                or not isinstance(field.get("title"), str) or len(field["title"].encode()) > 160
                or not isinstance(field.get("default"), str) or len(field["default"].encode()) > 2048
                or field["key"] in seen_keys):
            raise ValueError("invalid source setting field")
        seen_keys.add(field["key"])
    files = {}
    for path in sorted(source.rglob("*.lua")):
        if path.is_symlink() or any(p.is_symlink() for p in path.parents if p == source or source in p.parents):
            raise ValueError("symlinks are not source files")
        relative = path.relative_to(source).as_posix()
        if not re.fullmatch(r"[\w/-]+\.lua", relative, flags=re.ASCII) or len(relative) > 160:
            raise ValueError(f"invalid Lua path: {relative}")
        if relative.lower() in {p.lower() for p in files}:
            raise ValueError("case-colliding module paths")
        code = path.read_text(encoding="utf-8")
        if manifest["api_version"] == 3 and re.search(r"\bctx\s*[.:]\s*(host|base|module)\b", code):
            raise ValueError(f"API v3 uses named SDK services, not legacy host/base/module imports: {relative}")
        if "\0" in code or code.startswith("\x1b"):
            raise ValueError("only Lua text is accepted")
        luajit = shutil.which("luajit")
        if not luajit:
            raise ValueError("LuaJIT is required for source syntax validation")
        result = subprocess.run([luajit, "-b", str(path), "/dev/null"], capture_output=True)
        if result.returncode:
            raise ValueError(f"Lua syntax error: {relative}")
        files[relative] = code
    if not 0 < len(files) <= 64 or manifest["entry"] not in files:
        raise ValueError("invalid file count or missing entry")
    raw = encode({"format": 1, "manifest": manifest, "files": files})
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError("bundle exceeds 2 MiB")
    output.mkdir(parents=True, exist_ok=True)
    filename = f'{manifest["id"]}-{manifest["version"]}.pysource'
    if not base_url and not (output / "index.json").exists():
        for path in output.glob(manifest["id"] + "-*.pysource"):
            older = re.fullmatch(re.escape(manifest["id"]) + r"-(\d+)\.(\d+)\.(\d+)\.pysource", path.name)
            if older and tuple(map(int, older.groups())) > tuple(map(int, manifest["version"].split("."))):
                raise ValueError("newer local source version already exists; use a separate output directory")
    atomic(output / filename, raw, immutable=True)
    digest = hashlib.sha256(raw).hexdigest()
    if base_url:
        if not re.fullmatch(r"https://[A-Za-z0-9.-]+(?:/[^\s#]*)?", base_url):
            raise ValueError("base URL must use HTTPS")
        index_path = output / "index.json"
        old = json.loads(index_path.read_text(), object_pairs_hook=read_unique) if index_path.exists() else None
        if old and old.get("signed") == 1:
            if not sign_key:
                raise ValueError("cannot downgrade a signed repository")
            old = json.loads(old["payload"], object_pairs_hook=read_unique)
        index = old or {"format": 2 if sign_key else 1, "name": name, "sources": []}
        entry = {k: manifest[k] for k in ("id", "name", "version", "api_version", "min_app_version", "max_app_version", "publisher_id") if k in manifest}
        entry.update(url=base_url.rstrip("/") + "/" + filename, sha256=digest, notes=notes)
        for existing in index["sources"]:
            if existing["id"] == entry["id"] and existing["version"] == entry["version"] and existing["sha256"] != digest:
                raise ValueError("a published source version cannot change")
        if sign_key:
            if manifest["api_version"] not in (2, 3):
                raise ValueError("signed releases require API v2/v3 publisher identity")
            publisher = manifest["publisher_id"]
            if index.get("publisher_id", publisher) != publisher:
                raise ValueError("repository publisher cannot change")
            if revision is None or revision <= index.get("revision", 0):
                raise ValueError("signed catalogs require an increasing --revision")
            public, signature = sign(sign_key, "package", raw)
            entry.update(size=len(raw), signature=signature)
            index.update(format=2, publisher_id=publisher, revision=revision)
            index["sources"] = [e for e in index["sources"] if (e["id"], e["version"]) != (entry["id"], entry["version"])] + [entry]
            index["sources"].sort(key=lambda e: (e["id"], tuple(map(int, e["version"].split(".")))))
            if len(index["sources"]) > 200:
                raise ValueError("catalog exceeds 200 releases")
            # A rotated catalog re-signs retained immutable packages with the new
            # key. Keeping old-key signatures would make old releases unusable.
            for release in index["sources"]:
                package_path = output / f'{release["id"]}-{release["version"]}.pysource'
                retained = package_path.read_bytes()
                if hashlib.sha256(retained).hexdigest() != release["sha256"]:
                    raise ValueError("retained release digest mismatch")
                release["signature"] = sign(sign_key, "package", retained)[1]
            payload = encode(index)
            public, signature = sign(sign_key, "index", payload)
            envelope = {"signed": 1, "public_key": public, "signature": signature, "payload": payload.decode()}
            if rotation_key:
                envelope["rotation"] = sign(rotation_key, "rotation", (publisher + "\n" + public).encode())[1]
            result = encode(envelope)
        else:
            if index.get("format") != 1:
                raise ValueError("new catalog format requires signing")
            index["sources"] = sorted([s for s in index["sources"] if s["id"] != manifest["id"]] + [entry], key=lambda s: s["id"])
            result = encode(index)
        if len(result) > 512 * 1024:
            raise ValueError("catalog exceeds 512 KiB")
        atomic(index_path, result)
    prune_packages(output)
    return filename, digest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--out", type=Path, help="output directory (examples default to a temporary directory)")
    parser.add_argument("--base-url")
    parser.add_argument("--name", default="PicaYomi Sources")
    parser.add_argument("--notes", default="")
    parser.add_argument("--sign-key", type=Path, help="external Ed25519 PEM private key (never included in output)")
    parser.add_argument("--rotation-key", type=Path, help="previous external Ed25519 key")
    parser.add_argument("--revision", type=int)
    args = parser.parse_args()
    if args.out is None:
        manifest = json.loads((args.source / "manifest.json").read_text(), object_pairs_hook=read_unique)
        args.out = Path(tempfile.mkdtemp(prefix="picayomi-source-example-")) if manifest.get("id")=="example" else Path("dist/sources")
    filename, digest = build(args.source, args.out, args.base_url, args.name, args.notes, args.sign_key, args.revision, args.rotation_key)
    print(f"{args.out / filename}\nSHA-256 {digest}")
