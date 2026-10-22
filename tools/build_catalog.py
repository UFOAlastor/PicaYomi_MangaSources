#!/usr/bin/env python3
"""Sign an aggregate source catalog; keep the external signing key private."""
import argparse
import hashlib
import json
from pathlib import Path
from build_source import encode, sign, atomic


def catalog(packages, key, revision, base_url, output, name="PicaYomi 漫画源"):
    entries=[]
    for path in sorted(Path(packages).glob("*.pysource")):
        raw=path.read_bytes()
        m=json.loads(raw)["manifest"]
        entry={k:m[k] for k in ("id","name","version","api_version","min_app_version","max_app_version","publisher_id") if k in m}
        entry.update(url=base_url.rstrip("/")+"/"+path.name,sha256=hashlib.sha256(raw).hexdigest(),
                     size=len(raw),signature=sign(key,"package",raw)[1])
        entries.append(entry)
    if not entries or revision<1: raise ValueError("packages and a positive revision are required")
    payload=encode(dict(format=3,name=name,publisher_id="picayomi.sources",revision=revision,sources=entries))
    public,signature=sign(key,"index",payload)
    result=encode(dict(signed=1,public_key=public,signature=signature,payload=payload.decode()))
    if len(result)>512*1024: raise ValueError("catalog too large")
    output=Path(output)
    if output.exists():
        previous=json.loads(output.read_text())
        old=json.loads(previous["payload"])
        if old["revision"]>=revision:
            if output.read_bytes()==result: return
            raise ValueError("catalog revision must increase")
        for e in old["sources"]:
            for new in entries:
                if (e["id"],e["version"])==(new["id"],new["version"]) and e["sha256"]!=new["sha256"]:
                    raise ValueError("published source version cannot change")
    atomic(output,result)


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("packages",type=Path)
    p.add_argument("--key",type=Path,required=True)
    p.add_argument("--revision",type=int,required=True)
    p.add_argument("--base-url",required=True)
    p.add_argument("--out",type=Path,required=True)
    a=p.parse_args()
    catalog(a.packages,a.key,a.revision,a.base_url,a.out)
