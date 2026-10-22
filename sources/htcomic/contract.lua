-- API v3 projection of this package's existing, independently tested protocol.
-- Platform state and caches remain private to the implementation.
local V={}
local function identifier(value)
    assert(type(value)=="string" and value~="" or type(value)=="number" and value==value and math.abs(value)<math.huge,"平台标识无效")
    return tostring(value)
end
function V.wrap(ctx,implementation,options)
    options=options or {}
    local S={capabilities=implementation.capabilities,access=implementation.access}
    local order_maps={}
    local function copy(v)
        if type(v)=="userdata" then return nil end
        if type(v)~="table" then return v end
        local out={}; for k,item in pairs(v) do out[k]=copy(item) end; return out
    end
    local function failure(err,code)
        return false,nil,ctx.error(code or "network",type(err)=="string" and err or "平台请求失败",nil,nil,false)
    end
    local function fetch(method,...)
        local was_logged=implementation.isLoggedIn and implementation:isLoggedIn()
        local called,ok,data,err=pcall(implementation[method],implementation,...)
        if not called then return failure("平台响应结构已变化","protocol_changed") end
        if ok~=true then
            local expired=was_logged and implementation.isLoggedIn and not implementation:isLoggedIn()
            return failure(err,expired and "auth_expired" or "network")
        end
        return true,data,nil
    end
    local function manga(v)
        local categories=copy(v.categories)
        if type(categories)=="string" then categories=categories~="" and {categories} or {} end
        return {id=identifier(v._id),title=v.title,cover=v.thumb,author=v.author,description=v.description,
            tags=copy(v.tags),categories=categories,finished=v.finished,favorite=v.isFavourite,
            updated_at=v.update_time,stats={chapters=v.epsCount,pages=v.pagesCount,likes=v.likesCount,
                comments=v.commentsCount,views=v.viewsCount},chineseTeam=v.chineseTeam}
    end
    local function comment(v)
        local replies
        if type(v.replies)=="table" then replies={}; for i,r in ipairs(v.replies) do replies[i]=comment(r) end end
        return {id=identifier(v._id),content=v.content or "",author=copy(v.author) or {name="未知用户"},
            created_at=v.created_at,likesCount=v.likesCount,repliesCount=v.repliesCount,replies=replies}
    end
    local function list(method,request,...)
        request=request or {}
        local n=select("#",...)
        local args={...};args[n+1]=request.page or 1;args[n+2]=request.sort;args[n+3]=request.categories
        local ok,data,err=fetch(method,unpack(args,1,n+3))
        if not ok then return false,nil,err end
        local items={};for i,item in ipairs(data.comics) do items[i]=manga(item) end
        local more=tonumber(data.pages) and (tonumber(data.page) or request.page or 1)<tonumber(data.pages) or data.has_more==true
        local total=tonumber(data.total)
        if options.estimated_total and method=="getComics" then total=nil end
        return true,{items=items,has_more=more,next=more and {page=(tonumber(data.page) or request.page or 1)+1} or nil,
            total=total},nil
    end
    function S:init()
        implementation:init()
        if options.render then ctx.images.register("bands",{stage="render",module="scramble",fn="applyContext",version=1}) end
        return true,{success=true},nil
    end
    function S:getManga(id)
        local ok,data,err=fetch("getComicDetail",id)
        if not ok then return false,nil,err end
        return true,manga(data),nil
    end
    function S:getChapters(id)
        local episodes,seen,map={},{},{}
        for page=1,200 do
            local ok,data,err=fetch("getChapters",id,page)
            if not ok then return false,nil,err end
            if type(data)~="table" or type(data.episodes)~="table" then return failure("平台章节结构已变化","protocol_changed") end
            for _,ch in ipairs(data.episodes) do
                local chapter_id=identifier(ch._id or options.single_chapter_identity and id)
                if seen[chapter_id] then return failure("平台章节身份重复","protocol_changed") end
                seen[chapter_id]=true
                local order=options.legacy_order and ch.order or "c_"..chapter_id
                map[chapter_id]=order
                episodes[#episodes+1]={id=chapter_id,manga_id=id,title=ch.title,
                    legacy_order=options.legacy_order and ch.order or nil,page_count=ch.pagesCount}
                if #episodes>20000 then return failure("章节数量超过限额","resource_limit") end
            end
            if page>=(tonumber(data.pages) or 1) then
                if options.legacy_order then table.sort(episodes,function(a,b) return (tonumber(a.legacy_order) or 0)<(tonumber(b.legacy_order) or 0) end) end
                order_maps[id]=map
                return true,{items=episodes,has_more=false,total=#episodes},nil
            end
        end
        return failure("章节分页超过限额","resource_limit")
    end
    function S:getPages(id,chapter_id)
        if not (order_maps[id] and order_maps[id][chapter_id]) then
            local ok,_,err=self:getChapters(id);if not ok then return false,nil,err end
        end
        local order=order_maps[id] and order_maps[id][chapter_id]
        if order==nil then return failure("章节不存在","not_found") end
        local ok,data,err=fetch("getAllChapterImages",id,order)
        if not ok then return false,nil,err end
        local pages={}
        for i,image in ipairs(data.images) do
            local url=type(image)=="table" and image.url or image
            local context,processors
            if options.render then
                local bands=ctx.require("scramble").countForUrl(url)
                if bands>0 then context={bands=bands};processors={render={name="bands",version=1}} end
            end
            pages[i]={index=i,resource={url=url},context=context,processors=processors}
        end
        return true,{items=pages,complete=true},nil
    end
    function S:getImageRequest(resource)
        local headers,err=implementation:imageHeaders(resource.url)
        if type(headers)~="table" then return failure(err) end
        local values={};for k,v in pairs(headers) do values[k]=type(v)=="number" and tostring(v) or v end
        return ctx.imageRequest(resource,values)
    end
    function S:getLatest(request) return list("getComics",request) end
    function S:getRecommendations(request) return list("getRecommendations",request) end
    function S:search(keyword,request) return list("search",request,keyword) end
    function S:getCategoryComics(id,request) return list("getCategoryComics",request,id) end
    function S:getRankings(id,request) return list("getRankings",request,id) end
    function S:getFavorites(request) return list("getFavorites",request) end
    function S:getRandom(request) return list("getRandom",request) end
    function S:getCategories()
        local ok,data,err=fetch("getCategories")
        if not ok then return false,nil,err end
        local items={}; for i,item in ipairs(data) do items[i]={id=tostring(item._id or item.title),title=item.title,isWeb=item.isWeb,link=item.link} end
        return true,items,nil
    end
    function S:getRankingTypes()
        local items=implementation:getRankingTypes()
        return true,copy(items),nil
    end
    function S:getSortOptions(kind)
        local items={};for i,item in ipairs(implementation:getSortOptions(kind)) do items[i]={id=item.value,title=item.text} end
        return true,items,nil
    end
    function S:getSession() return true,{logged_in=implementation:isLoggedIn()},nil end
    function S:getCredential() return true,{token=implementation:getToken()},nil end
    function S:setCredential(token)
        if not implementation.setToken then return failure("当前源不支持导入会话","unsupported") end
        implementation:setToken(token);return true,{success=true},nil
    end
    function S:login(...)
        local ok,err=implementation:login(...)
        if not ok then return failure(err) end
        return true,{success=true},nil
    end
    function S:logout() implementation:logout();return true,{success=true},nil end
    function S:getUserProfile()
        local was_logged=implementation:isLoggedIn()
        local data,err=implementation:getUserProfile()
        if not data then
            local logged=implementation:isLoggedIn()
            return failure(err,was_logged and not logged and "auth_expired" or logged and "network" or "auth_required")
        end
        return true,copy(data),nil
    end
    for _,method in ipairs({"addFavorite","removeFavorite","punchIn"}) do
        S[method]=function(_,...)
            if type(implementation[method])~="function" then return failure("当前源不支持此功能","unsupported") end
            local ok,err=implementation[method](implementation,...)
            if not ok then return failure(err) end
            return true,{success=true},nil
        end
    end
    for method,key in pairs({getComments="comments",getCommentReplies="replies"}) do
        S[method]=function(_,id,comment_id,request)
            if key=="comments" then request,comment_id=comment_id,nil end
            local ok,data,err
            if key=="comments" then ok,data,err=fetch(method,id,(request or {}).page or 1)
            else ok,data,err=fetch(method,id,comment_id,(request or {}).page or 1) end
            if not ok then return false,nil,err end
            local items={};for i,item in ipairs(data[key]) do items[i]=comment(item) end
            local page=tonumber(data.page) or 1;local more=page<(tonumber(data.pages) or 1)
            return true,{items=items,has_more=more,next=more and {page=page+1} or nil,total=tonumber(data.total)},nil
        end
    end
    return S
end
return V
