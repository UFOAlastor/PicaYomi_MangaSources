-- Run inside KOReader with an isolated KO_HOME. Never claims an online result.
require("setupkoenv")
assert(os.getenv("KO_HOME") and os.getenv("KO_HOME")~="", "set KO_HOME to a temporary directory")
local host, filename, fixture_path=assert(arg[1],"host checkout required"),assert(arg[2],"package required"),arg[3]
package.path=host.."/?.lua;"..package.path
local json=require("rapidjson")
local function read(path)
    local f=assert(io.open(path,"rb"));local raw=f:read("*a");f:close();return raw
end
local pkg=require("source.extensions.package").decode(read(filename),dofile(host.."/_meta.lua").version)
local fixture=fixture_path and json.decode(read(fixture_path)) or {}
local settings={}
for _,field in ipairs(pkg.manifest.settings or {}) do settings[field.key]=field.default end
for k,v in pairs(fixture.settings or {}) do settings[k]=v end
local context=require("source.extensions.loader").open(pkg,require("ffi/sha2").sha256(read(filename)),
    function(key,default) local value=settings[key];if value==nil then return default end;return value end,false)
if fixture_path then
    context.ctx.http={get=function(_,url)
        assert(not context.ctx.initializing,"源初始化禁止联网")
        local response=assert((fixture.responses or {})[url],"fixture response missing: "..url)
        return json.decode(json.encode(response))
    end}
end
local source=require("source.extensions.loader").activate(context)
print("PASS package and activation: "..source.identifier.." "..source.version)
local function subset(actual,expected,path)
    if type(expected)~="table" then assert(actual==expected,path.." mismatch");return end
    assert(type(actual)=="table",path.." is not a table")
    for k,v in pairs(expected) do subset(actual[k],v,path.."."..tostring(k)) end
end
for i,case in ipairs(fixture.cases or {}) do
    assert(type(case.expect.ok)=="boolean","fixture must specify expect.ok")
    local ok,data,err
    if pkg.manifest.api_version==3 then ok,data,err=source:invoke(case.method,case.args or {})
    else
        local method=assert(source[case.method],"source method missing")
        ok,data,err=method(source,unpack(case.args or {}))
    end
    assert(ok==case.expect.ok,"case "..i..": "..tostring(err))
    if ok and (case.method=="getAllChapterImages" or case.method=="getChapterImages") then
        for _,image in ipairs(data.images) do
            assert(type(image)=="table" and type(image.url)=="string",
                "host must normalize source images; upgrade to PicaYomi 0.10.4")
        end
    end
    if case.expect.data then subset(data,case.expect.data,"case "..i) end
    for field,count in pairs(case.expect.counts or {}) do
        assert(type(data[field])=="table" and #data[field]==count,"case "..i.." count mismatch: "..field)
    end
    if case.expect.code then assert(type(err)=="table" and err.code==case.expect.code,"expected error code missing") end
    if case.expect.error then assert(tostring(type(err)=="table" and err.message or err):find(case.expect.error,1,true),"expected error missing") end
    print("PASS fixture "..i..": "..case.method)
end
print("Structural/fixture checks only; live platform and device acceptance not performed.")
