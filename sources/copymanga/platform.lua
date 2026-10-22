-- Independent platform adapter; no platform code is loaded by the host package.
-- Protocol references: Aidoku-Community/sources, sources/zh.copymanga (MIT/Apache-2.0).
-- Website authentication: the current site's loginStatic app and http_request.js.
-- The legacy App endpoint is anonymous compatibility only; see source author docs.
return function(ctx)
    local S = require("object"):extend{
        capabilities = { login = true, requires_login = false, recommendations = true,
            latest = true, search = true, categories = true, rankings = true,
            download = true, local_favorites = true, favorites = true },
        access = { favorites = "login" },
    }
    local function str(v) return type(v) == "string" and v or "" end
    local function encode(v)
        return (tostring(v):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end))
    end
    local function select(doc, query) return doc:select(query) or {} end
    local function text(node) return node and node:textonly():gsub("^%s+", ""):gsub("%s+$", "") or "" end
    local function attr(node, key) return node and node.attributes and node.attributes[key] end
    local function identifier(v)
        assert(type(v) == "string" and v:match("^[%w_%-]+$") and #v <= 160, "平台标识无效")
        return v
    end
    local function json(raw)
        local data = ctx.json.decode(raw)
        assert(type(data) == "table", "平台 JSON 格式已变化")
        return data
    end
    -- The public category page embeds a JS data literal, not executable JSON.
    -- Accept data tokens only; never evaluate code supplied by a website.
    local function literal(raw)
        local out, i = {}, 1
        while i <= #raw do
            local c = raw:sub(i,i)
            if c == "'" or c == '"' then
                local quote, value, closed = c, {}, false
                i = i + 1
                while i <= #raw do
                    c = raw:sub(i,i); i = i + 1
                    if c == quote then closed = true; break end
                    if c == "\\" then
                        local escaped = raw:sub(i,i); i = i + 1
                        if escaped == "u" or escaped == "x" then
                            local length = escaped=="u" and 4 or 2
                            local hex = raw:sub(i,i+length-1)
                            assert(#hex==length and hex:match("^%x+$"), "分类字符串转义无效")
                            value[#value+1] = ctx.json.decode('"\\u'..(length==2 and "00" or "")..hex..'"')
                            i=i+length
                        else
                            local escapes = {n="\n",r="\r",t="\t",b="\b",f="\f",["\\"]="\\",["'"]="'",['"']='"',["/"]="/"}
                            value[#value+1] = assert(escapes[escaped], "分类字符串转义无效")
                        end
                    else
                        assert(c:byte() >= 32, "分类字符串无效")
                        value[#value+1] = c
                    end
                end
                assert(closed, "分类字符串不完整")
                out[#out+1] = ctx.json.encode(table.concat(value))
            elseif c:match("[%s%d%[%]{}:,%.%+%-]") then
                out[#out+1]=c; i=i+1
            else
                local word = raw:sub(i):match("^%a+")
                assert(word=="true" or word=="false" or word=="null", "分类包含非数据内容")
                out[#out+1]=word; i=i+#word
            end
        end
        return json(table.concat(out))
    end
    local function decrypt(raw, key)
        assert(type(raw) == "string" and #raw > 16 and type(key) == "string" and #key == 16,
            "平台加密数据或密钥格式已变化")
        local hex = raw:sub(17)
        assert(#hex % 32 == 0 and hex:match("^[%da-fA-F]+$"), "平台密文格式已变化")
        local binary = hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
        return json(assert(ctx.aes.decrypt_cbc(key, binary, raw:sub(1, 16))))
    end
    function S:init() self._http_client = ctx.http end
    function S:baseURL()
        local url = ctx.getSetting("base_url", "https://www.copy5000.com"):gsub("/+$", "")
        assert(url:match("^https://[%w%.%-]+$"), "网站地址必须为 HTTPS 域名")
        return url
    end
    function S:absolute(url)
        if url:match("^https://") then return url end
        if url:sub(1, 2) == "//" then return "https:" .. url end
        assert(url:sub(1, 1) == "/", "平台 URL 无效")
        return self:baseURL() .. url
    end
    function S:imageHeaders()
        return { ["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0.1 Safari/605.1.15",
            Referer = self:baseURL() .. "/" }
    end
    function S:downloadImage(url, path, timeout)
        return ctx.http:download(url, path, self:imageHeaders(url), timeout or 20)
    end
    function S:get(path, extra)
        assert(type(path) == "string" and path:sub(1,1) == "/" and path:sub(1,2) ~= "//",
            "网站接口必须使用站内路径")
        local headers = self:imageHeaders()
        -- HTML/API and image CDN use distinct header policies.
        headers.Referer = nil
        for k, v in pairs(extra or {}) do headers[k] = v end
        local token = self:getToken()
        if token then
            headers.Authorization = "Token " .. token
            -- HTML navigation uses the same cookie as the official website.
            headers.Cookie = "token=" .. token
        end
        local response, err = ctx.http:get(self:baseURL() .. path, headers, 20)
        assert(response, err or "平台网络请求失败")
        if response.status_code == 401 and token then
            self:logout()
            error("登录已过期，请重新登录")
        end
        assert(response.status_code == 200, "平台 HTTP " .. tostring(response.status_code))
        assert(type(response.body) == "string" and #response.body > 0
            and #response.body <= 8 * 1024 * 1024, "平台响应大小无效")
        return response.body
    end
    local function protected(fn)
        return function(self, ...)
            local ok, value = pcall(fn, self, ...)
            if not ok then return false, nil, tostring(value) end
            return true, value
        end
    end
    function S:apiBaseURL()
        local base = ctx.getSetting("api_base_url", "https://api.2024manga.com"):gsub("/+$", "")
        assert(base:match("^https://[%w%.%-]+$"), "API 地址必须为 HTTPS 域名")
        return base
    end
    function S:getToken()
        local session = ctx.secrets.get_json("session")
        if type(session) == "table" and session.origin == self:baseURL()
            and type(session.token) == "string" and #session.token <= 8192
            and session.token:match("^[%w._%-]+$") then
            return session.token
        end
    end
    function S:isLoggedIn() return self:getToken() ~= nil end
    function S:logout()
        local cleared = ctx.secrets.clear("session")
        assert(cleared, "无法清除登录态，请重试")
    end
    function S:accountRequest(path, body, token, empty_result)
        assert(type(path)=="string" and path:sub(1,1)=="/" and path:sub(1,2)~="//",
            "账号接口必须使用站内路径")
        local headers = self:imageHeaders(); headers.Referer = nil
        headers.platform = "2"
        headers.Authorization = "Token " .. (token or "")
        local response, err
        if body then
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            response, err = ctx.http:post(self:baseURL() .. path, headers, body, 20)
        else
            response, err = ctx.http:get(self:baseURL() .. path, headers, 20)
        end
        if not response then return nil, err or "账号接口网络请求失败" end
        if type(response.body) ~= "string" or #response.body > 1024 * 1024 then
            return nil, "账号接口响应大小无效"
        end
        local ok, data = pcall(json, response.body)
        if response.status_code == 401 or ok and tonumber(data.code) == 401 then
            -- Do not discard an existing session after a failed attempt to log into another account.
            if token and token == self:getToken() then self:logout() end
            return nil, "登录已过期，请重新登录"
        end
        if ok and tonumber(data.code) == 210 then
            return nil, "平台拒绝登录 (code 210)，请在官网确认账号及访问限制"
        end
        if not ok or response.status_code ~= 200 then
            return nil, "账号接口响应无效 (HTTP " .. tostring(response.status_code) .. ")"
        end
        if tonumber(data.code) ~= 200 or (type(data.results) ~= "table" and not empty_result) then
            -- Never propagate an arbitrary response body containing personal information.
            return nil, "账号请求失败，请检查账号密码或稍后重试 (code " .. tostring(tonumber(data.code) or 0) .. ")"
        end
        return type(data.results)=="table" and data.results or {}
    end
    function S:login(username, password)
        if type(username) ~= "string" or username == "" or type(password) ~= "string" or password == "" then
            return false, "用户名和密码不能为空"
        end
        local salt = tostring(math.random(100000, 999999))
        local body = "username=" .. encode(username) .. "&password="
            .. encode(ctx.b64.encode(password .. "-" .. salt))
            .. "&salt=" .. salt .. "&platform=2&version=2025.12.10&source=freeSite"
        local result, err = self:accountRequest("/api/kb/web/login", body)
        if not result then return false, err end
        if type(result.token) ~= "string" or #result.token > 8192 or not result.token:match("^[%w._%-]+$") then
            return false, "登录响应缺少有效 token"
        end
        -- Persist only the session; no password or unneeded account information is retained.
        if not ctx.secrets.set_json("session", { token = result.token, origin = self:baseURL() }) then
            return false, "登录成功但无法加密保存登录态，请重试"
        end
        return true
    end
    function S:getUserProfile()
        local token = self:getToken()
        if not token then return nil, "请先登录" end
        local result, err = self:accountRequest("/api/v2/web/user/info", nil, token)
        if not result then return nil, err end
        local id = result.user_id or result.uuid or result.uid or result.id
        local name = str(result.nickname)
        if name == "" then name = str(result.username) end
        if not (type(id) == "string" and id ~= "" or type(id) == "number") or name == "" then
            return nil, "用户资料结构已变化"
        end
        return { id = tostring(id), name = name, avatar = str(result.avatar) }
    end
    function S:api(path)
        local headers = self:imageHeaders(); headers.Referer = nil
        local response, err = ctx.http:get(self:apiBaseURL() .. path, headers, 20)
        assert(response and response.status_code == 200, err or "App API 网络请求失败")
        local data = json(response.body)
        assert(data.code == 200 and type(data.results) == "table", "App API 响应无效")
        return data.results
    end
    function S:apiChapters(id)
        local detail = self:api("/api/v3/comic2/" .. identifier(id) .. "?platform=3")
        assert(detail.is_lock ~= true, "该作品需要平台授权访问")
        assert(type(detail.groups) == "table", "App API 章节分组无效")
        local groups, episodes, seen = {}, {}, {}
        for name in pairs(detail.groups) do groups[#groups + 1] = identifier(name) end
        table.sort(groups, function(a, b)
            if a == b then return false end
            if a == "default" then return true end
            if b == "default" then return false end
            return a < b
        end)
        for _, name in ipairs(groups) do
            local entries, offset = {}, 0
            repeat
                assert(offset < 20000, "章节数量超出上限")
                local page = self:api("/api/v3/comic/" .. id .. "/group/" .. name
                    .. "/chapters?limit=100&offset=" .. offset .. "&platform=3")
                assert(type(page.list) == "table" and tonumber(page.offset) == offset,
                    "App API 章节分页无效")
                for _, ch in ipairs(page.list) do entries[#entries + 1] = ch end
                offset = offset + #page.list
                if #page.list == 0 then
                    assert(offset >= (tonumber(page.total) or 0), "章节列表未完整返回")
                    break
                end
            until offset >= (tonumber(page.total) or offset)
            table.sort(entries, function(a, b)
                local x, y = tonumber(a.ordered) or 0, tonumber(b.ordered) or 0
                if x ~= y then return x < y end
                return tostring(a.uuid) < tostring(b.uuid)
            end)
            for _, ch in ipairs(entries) do
                local uuid = identifier(ch.uuid)
                if not seen[uuid] then
                    episodes[#episodes + 1] = { _id = uuid, order = "c_" .. uuid,
                        title = str(detail.groups[name].name) .. " · " .. str(ch.name),
                        sort_index = #episodes + 1, pagesCount = tonumber(ch.size) }
                    seen[uuid] = true
                end
            end
        end
        assert(#episodes > 0, "平台没有返回可读章节")
        return { episodes = episodes, page = 1, pages = 1, total = #episodes }
    end
    function S:parseList(raw, page, per, selector)
        local doc = ctx.html.parse(raw)
        local comics, seen = {}, {}
        local metadata={}
        -- Metadata belongs to a card, never to the next work's adjacent link.
        for _,class in ipairs({".exemptComic_Item",".ranking-all-box"}) do
            for _,card in ipairs(select(doc,(selector and selector.." " or "")..class)) do
                local id,authors,author_seen=nil,{},{}
                for _,link in ipairs(select(card,"a[href]")) do
                    local href=attr(link,"href") or ""
                    id=id or href:match("^/comic/([%w_%-]+)$")
                    if href:match("^/author/[^/]+/comics$") then
                        local name=text(link)
                        if name~="" and not author_seen[name] then authors[#authors+1]=name;author_seen[name]=true end
                    end
                end
                if id then
                    local heat=text(select(card,".update")[1]):gsub("%s+","")
                    metadata[id]={author=table.concat(authors," / "),
                        metadata=heat:match("^[%d%.,]+[Ww万萬亿億]*$") and {heat=heat} or nil}
                end
            end
        end
        local titles = {}
        for _, a in ipairs(select(doc, (selector and selector .. " " or "") .. "a[href]")) do
            local id = (attr(a, "href") or ""):match("^/comic/([%w_%-]+)$")
            local title = text(select(a, "p")[1])
            if id and title ~= "" then titles[id] = title end
        end
        for _, a in ipairs(select(doc, (selector and selector .. " " or "") .. "a[href]")) do
            local href = attr(a, "href") or ""
            local id = href:match("^/comic/([%w_%-]+)$")
            local image = select(a, "img")[1]
            local cover = attr(image, "data-src") or attr(image, "src")
            if id and cover and not seen[id] then
                local title = text(select(a, "p")[1])
                if title == "" then title = titles[id] or attr(image, "alt") or attr(a, "title") or id end
                if title == "" then title = id end
                local extra=metadata[id] or {}
                comics[#comics + 1] = { _id = id, title = title, thumb = self:absolute(cover),
                    author = extra.author or "",metadata=extra.metadata }
                seen[id] = true
            end
        end
        assert(#comics > 0, "列表未找到作品，网站结构可能已变化")
        local pages = page
        for _, item in ipairs(select(doc, "li.page-all-item")) do
            local n = tonumber(text(item))
            if n and n > pages then pages = n end
        end
        return { comics = comics, page = page, pages = pages, total = (pages - 1) * per + #comics }
    end
    S.getComics = protected(function(self, page)
        page = math.max(1, tonumber(page) or 1)
        return self:parseList(self:get("/newest?offset=" .. (page - 1) * 60 .. "&limit=60"), page, 60)
    end)
    S.getLatest = S.getComics
    -- These are platform values, consumed by the shared category/list pages.
    function S:getSortOptions(kind)
        if kind == "favorites" then
            return {{value="-datetime_modifier",text="最近收藏"},
                {value="-datetime_updated",text="最近更新"}}
        end
        if kind ~= "category" then return {} end
        return { {value="-datetime_updated",text="最近更新"},
            {value="datetime_updated",text="最早更新"}, {value="-popular",text="人气"} }
    end
    S.getCategories = protected(function(self)
        local doc = ctx.html.parse(self:get("/filter"))
        local categories, seen = {}, {}
        for _, a in ipairs(select(doc, "a[href]")) do
            local id = (attr(a,"href") or ""):match("^/comics%?theme=([%w_%-]+)$")
            if id and not seen[id] then
                local title = text(a):gsub("%s*%(%d+%)%s*$", "")
                assert(title ~= "", "分类缺少名称")
                categories[#categories+1] = {_id=identifier(id), title=title}
                seen[id] = true
            end
        end
        assert(#categories > 0, "分类结构已变化")
        return categories
    end)
    S.getCategoryComics = protected(function(self, category, page, sort)
        page = math.max(1, tonumber(page) or 1)
        sort = sort or "-datetime_updated"
        assert(sort=="-datetime_updated" or sort=="datetime_updated" or sort=="-popular", "分类排序无效")
        local doc = ctx.html.parse(self:get("/comics?theme=" .. identifier(category) .. "&ordering=" .. sort
            .. "&offset=" .. (page-1)*50 .. "&limit=50"))
        local box = select(doc, ".exemptComic-box")[1]
        local total = tonumber(attr(box,"total"))
        assert(total and total >= 0, "分类总数无效")
        local raw = assert(attr(box,"list"), "分类列表结构已变化")
        local items = literal(ctx.text.htmlEntitiesToUtf8(raw))
        local comics = {}
        for _, item in ipairs(items) do
            assert(type(item)=="table" and str(item.name)~="", "分类作品无效")
            local authors={}
            for _,author in ipairs(type(item.author)=="table" and item.author or {}) do
                if type(author)=="table" and str(author.name)~="" then authors[#authors+1]=author.name end
            end
            local status=tonumber(item.status)
            local finished
            if status==0 then finished=false elseif status==1 then finished=true end
            comics[#comics+1] = {_id=identifier(item.path_word),title=item.name,
                thumb=self:absolute(str(item.cover)),author=table.concat(authors," / "),finished=finished,
                metadata=status==2 and {status="短篇"} or nil}
        end
        assert(#comics > 0 or (page-1)*50 >= total, "分类列表未完整返回")
        return {comics=comics,total=total,page=page,pages=math.max(1,math.ceil(total/50))}
    end)
    function S:getRankingTypes()
        local types = {}
        for _, audience in ipairs({{"male","男频"},{"female","女频"}}) do
            for _, period in ipairs({{"day","日榜"},{"week","周榜"},{"month","月榜"},{"total","总榜"}}) do
                types[#types+1] = {id=audience[1].."_"..period[1],title=audience[2].." · "..period[2]}
            end
        end
        return types
    end
    S.getRankings = protected(function(self, rank, page)
        assert((tonumber(page) or 1)==1, "网站排行榜只有一页")
        local audience, period = str(rank):match("^(%a+)_(%a+)$")
        assert((audience=="male" or audience=="female") and
            (period=="day" or period=="week" or period=="month" or period=="total"), "排行榜类型无效")
        local data = self:parseList(self:get("/rank?type="..audience.."&table="..period), 1, 50, ".ranking-all")
        data.pages, data.total = 1, #data.comics
        return data
    end)
    S.getRecommendations = protected(function(self, page)
        assert((tonumber(page) or 1) == 1, "推荐区只有一页")
        local doc = ctx.html.parse(self:get("/"))
        local comics, seen = {}, {}
        for _, section in ipairs(select(doc, "div.container")) do
            local heading = text(select(section, ".index-all-icon-left-txt")[1]):gsub("%s+", "")
            if heading == "漫畫推薦" or heading == "漫画推荐" then
                for _, a in ipairs(select(section, "a[href]")) do
                    local id = (attr(a, "href") or ""):match("^/comic/([%w_%-]+)$")
                    local img = select(a, "img")[1]
                    local cover = attr(img, "data-src") or attr(img, "src")
                    if id and cover and not seen[id] then
                        local title = text(select(a, "p.edit-txt")[1])
                        if title == "" then title = attr(img,"alt") or attr(a,"title") or id end
                        comics[#comics+1]={_id=id,title=title,thumb=self:absolute(cover),author=""}
                        seen[id]=true
                    end
                end
            end
        end
        assert(#comics>0,"首页推荐区未找到作品，网站结构可能已变化")
        return {comics=comics,page=1,pages=1,total=#comics}
    end)
    S.search = protected(function(self, keyword, page)
        assert(type(keyword) == "string" and #keyword > 0, "请输入关键词")
        page = math.max(1, tonumber(page) or 1)
        local search = self:get("/search")
        local api = assert(search:match('const%s+countApi%s*=%s*"([^"]+)"'), "搜索接口结构已变化")
        -- Source pages only supply a relative API path. Never concatenate arbitrary origins.
        assert(api:sub(1, 1) == "/" and api:sub(1, 2) ~= "//", "搜索接口地址无效")
        local data = json(self:get(api .. "?offset=" .. (page - 1) * 12
            .. "&limit=12&platform=2&q=" .. encode(keyword) .. "&q_type="))
        local result = data.results
        assert(type(result) == "table" and type(result.list) == "table", "搜索响应结构已变化")
        local comics = {}
        for _, item in ipairs(result.list) do
            assert(type(item) == "table", "搜索条目无效")
            local authors = {}
            for _, a in ipairs(type(item.author) == "table" and item.author or {}) do
                if type(a) == "table" and str(a.name) ~= "" then authors[#authors + 1] = a.name end
            end
            comics[#comics + 1] = { _id = identifier(item.path_word), title = str(item.name),
                author = table.concat(authors, " / "), thumb = self:absolute(str(item.cover)) }
        end
        local total = tonumber(result.total) or #comics
        return { comics = comics, total = total, page = page, pages = math.max(1, math.ceil(total / 12)) }
    end)
    S.getComicDetail = protected(function(self, id)
        local raw = self:get("/comic/" .. identifier(id))
        local doc = ctx.html.parse(raw)
        local title = text(select(doc, "h6")[1])
        assert(title ~= "", "详情结构已变化")
        local image = select(doc, "img[data-src]")[1]
        local authors, tags = {}, {}
        for _, a in ipairs(select(doc, "span.comicParticulars-right-txt a")) do authors[#authors + 1] = text(a) end
        for _, a in ipairs(select(doc, "span.comicParticulars-tag a")) do tags[#tags + 1] = text(a) end
        local favorite
        if self:isLoggedIn() then
            local label = text(select(doc, ".collect")[1])
            if label == "取消收藏" then favorite = true
            elseif label == "加入書架" or label == "加入书架" then favorite = false end
        end
        return { _id = id, title = title, author = table.concat(authors, " / "), tags = tags,
            isFavourite = favorite,
            description = text(select(doc, "p.intro")[1]),
            thumb = self:absolute(assert(attr(image, "data-src"), "缺少封面")) }
    end)
    S.getFavorites = protected(function(self, page, sort)
        page = tonumber(page) or 1
        assert(page>=1 and page==math.floor(page), "收藏页码无效")
        sort = sort or "-datetime_modifier"
        assert(sort=="-datetime_modifier" or sort=="-datetime_updated", "收藏排序无效")
        local token = assert(self:getToken(), "请先登录")
        local result, err = self:accountRequest("/api/v3/member/collect/comics?limit=12&offset="
            .. (page-1)*12 .. "&free_type=1&ordering=" .. sort, nil, token)
        assert(result, err)
        local total = tonumber(result.total)
        assert(type(result.list)=="table" and total and total>=0 and total==math.floor(total),
            "收藏列表结构已变化")
        assert(result.offset==nil or tonumber(result.offset)==(page-1)*12, "收藏分页无效")
        local comics = {}
        for _, item in ipairs(result.list) do
            local comic = type(item)=="table" and item.comic
            assert(type(comic)=="table" and str(comic.name)~="", "收藏作品结构已变化")
            comics[#comics+1] = {_id=identifier(comic.path_word),title=comic.name,
                thumb=self:absolute(str(comic.cover)),isFavourite=true}
        end
        assert(#comics<=12 and (#comics>0 or (page-1)*12>=total), "收藏列表未完整返回")
        return {comics=comics,page=page,pages=math.max(1,math.ceil(total/12)),total=total}
    end)
    function S:setFavorite(id, wanted)
        local ok, err = pcall(function()
            local token = assert(self:getToken(), "请先登录")
            -- The public path_word remains our data identity; the website's
            -- collect action takes a distinct UUID supplied by its detail page.
            local doc = ctx.html.parse(self:get("/comic/" .. identifier(id)))
            local button = assert(select(doc,".collect")[1], "网站未返回收藏操作")
            local uuid = identifier(assert((attr(button,"onclick") or ""):match(
                "^%s*collect%s*%(%s*['\"]([%w_%-]+)['\"]%s*%)%s*;?%s*$"), "收藏标识结构已变化"))
            local label = text(button)
            local current
            if label=="取消收藏" then current=true
            elseif label=="加入書架" or label=="加入书架" then current=false
            else error("收藏状态结构已变化") end
            -- Set semantics: repeated add/remove never toggles the server state.
            if current==wanted then return end
            local result, request_error = self:accountRequest("/api/v2/web/collect",
                "comic_id="..encode(uuid).."&is_collect="..(wanted and "1" or "0"), token, true)
            assert(result, request_error)
        end)
        if not ok then return false, tostring(err) end
        return true
    end
    function S:addFavorite(id) return self:setFavorite(id,true) end
    function S:removeFavorite(id) return self:setFavorite(id,false) end
    local function key(raw)
        return assert(raw:match("var%s+[%w_]+%s*=%s*'([^']+)'"), "平台密钥结构已变化")
    end
    function S:webChapters(id)
        local raw = self:get("/comic/" .. identifier(id))
        local doc = ctx.html.parse(raw)
        local dnt = attr(select(doc, "#dnt")[1], "value") or "2"
        local data = json(self:get("/comicdetail/" .. id .. "/chapters", { dnts = dnt }))
        local result = decrypt(data.results, key(raw))
        -- Some mirrors publish a dnt value for an empty catalogue while the
        -- regular web catalogue remains available under the default value.
        local count = 0
        for _, group in pairs(type(result.groups) == "table" and result.groups or {}) do
            count = count + (type(group.chapters) == "table" and #group.chapters or 0)
        end
        if count == 0 and dnt ~= "2" then
            result = decrypt(json(self:get("/comicdetail/" .. id .. "/chapters", { dnts = "2" })).results, key(raw))
        end
        assert(type(result.groups) == "table", "章节分组结构已变化")
        local names, episodes, seen = {}, {}, {}
        for name in pairs(result.groups) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local group = result.groups[name]
            assert(type(group) == "table" and type(group.chapters) == "table", "章节分组无效")
            for _, ch in ipairs(group.chapters) do
                local chapter_id = identifier(ch.id)
                if not seen[chapter_id] then
                    episodes[#episodes + 1] = { _id = chapter_id, order = "c_" .. chapter_id,
                        title = (str(group.name) ~= "" and group.name .. " · " or "") .. str(ch.name),
                        sort_index = #episodes + 1 }
                    seen[chapter_id] = true
                end
            end
        end
        assert(#episodes > 0, "网站未返回可读章节")
        return { episodes = episodes, page = 1, pages = 1, total = #episodes }
    end
    S.getChapters = protected(function(self, id)
        if self._app_comics then self._app_comics[id] = nil end
        -- Logged-in reading must use the same origin and session as account APIs.
        -- The legacy App endpoint does not accept the website token. Keep it only
        -- as an anonymous compatibility fallback, never as a login workaround.
        local authenticated = self:isLoggedIn()
        local web_ok, web_data = pcall(self.webChapters, self, id)
        if web_ok then return web_data end
        if authenticated then error(web_data) end
        local app_ok, app_data = pcall(self.apiChapters, self, id)
        if not app_ok then error(tostring(web_data) .. "; 匿名 App 接口失败: " .. tostring(app_data)) end
        self._app_comics = self._app_comics or {}
        self._app_comics[id] = true
        return app_data
    end)
    function S:apiImages(id, uuid)
        local data = self:api("/api/v3/comic/" .. identifier(id) .. "/chapter/"
            .. identifier(uuid) .. "?platform=3")
        assert(data.is_lock ~= true, "该章节需要平台授权访问")
        local chapter = data.chapter
        assert(type(chapter) == "table" and chapter.uuid == uuid
            and type(chapter.contents) == "table" and #chapter.contents > 0,
            "App API 未返回章节图片")
        assert(tonumber(chapter.size) == #chapter.contents, "平台未返回完整章节图片")
        local images = {}
        for _, item in ipairs(chapter.contents) do
            assert(type(item) == "table" and type(item.url) == "string", "App API 图片条目无效")
            images[#images + 1] = self:absolute(item.url)
        end
        return { images = images }
    end
    S.getAllChapterImages = protected(function(self, id, chapter)
        assert(type(chapter) == "string" and chapter:sub(1, 2) == "c_", "章节标识无效")
        if self._app_comics and self._app_comics[id] and not self:isLoggedIn() then
            return self:apiImages(id, chapter:sub(3))
        end
        local raw = self:get("/comic/" .. identifier(id) .. "/chapter/" .. identifier(chapter:sub(3)))
        local encrypted = raw:match("var%s+contentKey%s*=%s*'([^']*)'")
        if not encrypted or encrypted == "" then
            assert(not self:isLoggedIn(), "网站未返回可读图片，请在平台确认访问条件")
            return self:apiImages(id, chapter:sub(3))
        end
        local data = decrypt(encrypted, key(raw))
        local images = {}
        for _, item in ipairs(data) do
            assert(type(item) == "table" and type(item.url) == "string", "图片条目无效")
            images[#images + 1] = self:absolute(item.url)
        end
        assert(#images > 0, "章节没有图片")
        return { images = images }
    end)
    function S:getChapterImages(id, chapter) return self:getAllChapterImages(id, chapter) end
    return S
end
