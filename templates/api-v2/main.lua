-- Teaching protocol only. Replace mappings using evidence from the real platform.
return function(ctx)
    local S = ctx.base:extend{capabilities={latest=true,search=true,download=true,local_favorites=true}}
    local function id(value)
        assert(type(value)=="string" and #value<=160 and value:match("^[%w_%-]+$"), "平台标识无效")
        return value
    end
    local function encode(value)
        return (tostring(value):gsub("([^%w%-_%.~])",function(c) return string.format("%%%02X",c:byte()) end))
    end
    local function protected(fn)
        return function(self,...)
            local ok,data=pcall(fn,self,...)
            if not ok then return false,nil,tostring(data) end
            return true,data
        end
    end
    function S:init() self._http_client=ctx.http end
    function S:baseURL()
        local value=ctx.getSetting("base_url","https://api.example.invalid"):gsub("/+$","")
        assert(value:match("^https://[%w%.%-]+$"),"API 地址必须为 HTTPS 域名")
        return value
    end
    function S:imageHeaders() return {Referer=self:baseURL().."/"} end
    function S:fetch(path)
        local response,err=ctx.http:get(self:baseURL()..path,{},20)
        assert(response,err or "平台请求失败")
        assert(response.status_code==200,"平台 HTTP "..tostring(response.status_code))
        local data=ctx.json.decode(assert(response.body,"平台响应为空"))
        assert(type(data)=="table","平台 JSON 结构已变化")
        return data
    end
    local function comics(data)
        assert(type(data.items)=="table","缺少作品列表")
        local items={}
        for _,item in ipairs(data.items) do
            assert(type(item.title)=="string" and item.title~="","缺少作品标题")
            items[#items+1]={_id=id(item.id),title=item.title,thumb=item.cover}
        end
        return {comics=items,page=data.page,pages=data.pages,total=data.total}
    end
    S.getComics=protected(function(self,page)
        return comics(self:fetch("/comics?page="..math.max(1,tonumber(page) or 1)))
    end)
    S.getLatest=S.getComics
    S.search=protected(function(self,keyword,page)
        assert(type(keyword)=="string" and keyword~="","请输入关键词")
        return comics(self:fetch("/search?q="..encode(keyword).."&page="..math.max(1,tonumber(page) or 1)))
    end)
    S.getComicDetail=protected(function(self,comic_id)
        local data=self:fetch("/comic/"..id(comic_id))
        assert(data.id==comic_id and type(data.title)=="string","作品详情无效")
        return {_id=comic_id,title=data.title,thumb=data.cover,description=data.description or ""}
    end)
    S.getChapters=protected(function(self,comic_id)
        local data=self:fetch("/comic/"..id(comic_id).."/chapters")
        assert(type(data.items)=="table","缺少章节列表")
        local episodes={}
        for _,chapter in ipairs(data.items) do
            episodes[#episodes+1]={_id=id(chapter.id),title=chapter.title}
        end
        return {episodes=episodes,page=1,pages=1,total=#episodes}
    end)
    S.getAllChapterImages=protected(function(self,comic_id,order)
        assert(type(order)=="string" and order:sub(1,2)=="c_","章节标识无效")
        local data=self:fetch("/comic/"..id(comic_id).."/chapter/"..id(order:sub(3)))
        assert(type(data.images)=="table" and #data.images>0,"章节没有返回图片")
        for _,url in ipairs(data.images) do assert(type(url)=="string" and url:match("^https://"),"图片 URL 无效") end
        return {images=data.images}
    end)
    return S
end
