-- Fictional teaching protocol. Replace it using real platform evidence.
return function(ctx)
    local S={capabilities={latest=true,search=true,download=true,local_favorites=true},
        list_display={subtitle={"author","categories"},details={"finished","stats.chapters","stats.pages","updated_at"}}}
    local function encode(value)
        return (tostring(value):gsub("([^%w%-_%.~])",function(c) return string.format("%%%02X",c:byte()) end))
    end
    local function endpoint()
        local base=ctx.getSetting("base_url","https://api.example.invalid"):gsub("/+$","")
        assert(base:match("^https://[%w%.%-]+$"),"invalid API origin")
        return base
    end
    local function fetch(path)
        local response,err=ctx.http:get(endpoint()..path,{},20)
        if not response then return nil,ctx.error("network","平台请求失败",nil,nil,true) end
        if response.status_code==401 then return nil,ctx.error("auth_expired","登录已过期") end
        if response.status_code~=200 then return nil,ctx.error("network","平台 HTTP 请求失败",nil,nil,response.status_code>=500) end
        local ok,data=pcall(ctx.json.decode,response.body)
        if not ok or type(data)~="table" then return nil,ctx.error("protocol_changed","平台响应结构已变化") end
        return data
    end
    local function result(path)
        local data,err=fetch(path)
        if not data then return false,nil,err end
        return true,data,nil -- The host validates every DTO before consumption.
    end
    function S:init()
        ctx.images.register("bands",{stage="render",module="processors",fn="bands",version=1})
        ctx.images.register("base64",{stage="file",module="processors",fn="base64",version=1})
        return true,{success=true},nil
    end
    local function suffix(request)
        return request and request.cursor and "?cursor="..encode(request.cursor) or ""
    end
    function S:getLatest(request) return result("/comics"..suffix(request)) end
    function S:search(keyword,request)
        return result("/search?q="..encode(keyword)..(request and request.cursor and "&cursor="..encode(request.cursor) or ""))
    end
    function S:getManga(id) return result("/comic/"..encode(id)) end
    function S:getChapters(id,request) return result("/comic/"..encode(id).."/chapters"..suffix(request)) end
    function S:getPages(id,chapter_id)
        local data,err=fetch("/comic/"..encode(id).."/chapter/"..encode(chapter_id))
        if not data then return false,nil,err end
        if type(data.images)~="table" then return false,nil,ctx.error("protocol_changed","章节图片结构已变化") end
        local pages={}
        for i,image in ipairs(data.images) do
            pages[i]={index=i,resource={url=image.url},context=image.context,processors={
                file=image.encoding=="base64" and {name="base64",version=1} or nil,
                render=image.context and image.context.bands and {name="bands",version=1} or nil,
            }}
        end
        return true,{items=pages,complete=true},nil
    end
    function S:getImageRequest(resource)
        local headers={Referer=endpoint().."/"}
        -- Optional fictional image credential: read at dispatch, never in Pages.
        local token=ctx.secrets.get("image_token")
        if token then headers.Authorization="Bearer "..token end
        return ctx.imageRequest(resource,headers,20)
    end
    return S
end
