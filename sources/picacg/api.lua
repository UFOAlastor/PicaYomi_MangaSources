local ctx = assert(ctx, "source SDK context required")
-- source/picacg/api.lua
-- 源 A API 方法
-- 从 api/comic.lua 重构，统一响应处理

local logger = ctx.logger
local json = ctx.json
local config = ctx.config
local cache = ctx.cache
local JN = ctx.values
local B64 = ctx.b64

local PicacgAPI = {}

-- 缓存有效期 (秒)
local CACHE_TTL = {
    CATEGORIES = 86400,   -- 1 天
    COMICS     = 3600,    -- 1 小时
    DETAIL     = 86400,   -- 1 天
    EPISODES   = 3600,    -- 1 小时
    IMAGES     = 3600,    -- 1 小时
    SEARCH     = 1800,    -- 30 分钟
    FAVORITES  = 1800,    -- 30 分钟
    RANKING    = 3600,    -- 1 小时
    COMMENTS   = 600,     -- 10 分钟 (评论变动快, 缓存短一些)
}

--- 统一 API 请求
-- @param http_client: HttpClient 实例
-- @param headers: Headers 模块
-- @param auth: Auth 模块
-- @param method: "GET"/"POST"/"DELETE"
-- @param path: API 路径 (如 "comics/xxx" 或 "auth/sign-in")
-- @param body: 请求体 (POST 时传入)
-- @return: response_data 表 (有 code/message/data) 或 nil, err
function PicacgAPI:request(http_client, headers, auth, method, path, body, no_retry)
    local token = auth:getToken()
    -- 允许部分接口无 token (如登录)
    local req_headers = headers:build(path, method, token)
    if not req_headers then
        return nil, "请求头构造失败"
    end

    local url = headers:buildUrl(path)
    local send = no_retry and http_client.request or http_client.requestWithRetry
    local response, err = send(http_client, method, url, req_headers, body, 15)

    if not response then
        return nil, "网络请求失败: " .. tostring(err)
    end

    -- 解析 JSON
    local data = http_client:parseJsonResponse(response)
    if not data then
        -- 可能是非 JSON 响应 (如 HTML 错误页)
        logger.err("Picayomi SourceAAPI: JSON 解析失败, path=" .. path ..
            ", status=" .. tostring(response.status_code) ..
            ", body_len=" .. #(response.body or ""))
        local status = tonumber(response.status_code)
        if status and status >= 400 then return nil, "服务器返回错误 (HTTP " .. status .. ")" end
        return nil, "响应解析失败"
    end

    -- 标准化响应: 确保有 code/message/data
    if data.code == nil then data.code = response.status_code end
    if data.data == nil then data.data = {} end

    return data
end

--- 判断响应是否成功
local function isOk(data)
    return data and (data.code == 200 or data.message == "success")
end

--- 从漫画表提取标准化字段
-- 注意: KOReader 的 rapidjson 把 JSON null 解码为真值 userdata,
-- 因此不能用 `x or "默认值"`, 必须用 JN 系列做类型过滤。
--- 只保留日期部分: 源 A 给的是 ISO 串 ("2025-05-04T13:04:31.435Z")
-- 卡片与详情页都按 "YYYY-MM-DD" 展示; 认不出格式就原样返回 (至少不丢信息)。
local function date_only(v)
    local s = JN.str(v)
    if not s or s == "" then return nil end
    return s:match("^(%d%d%d%d%-%d%d%-%d%d)") or s
end

local function normalizeComic(comic)
    if not comic or type(comic) ~= "table" then return nil end

    local thumb_url = ""
    if type(comic.thumb) == "table" then
        local fs = JN.str(comic.thumb.fileServer)
        local path = JN.str(comic.thumb.path)
        if fs and path then
            thumb_url = fs .. "/static/" .. path
        end
    elseif type(comic.thumb) == "string" then
        thumb_url = comic.thumb
    end

    local tags = JN.str_list(comic.tags)
    for _idx, c in ipairs(JN.str_list(comic.categories)) do
        table.insert(tags, c)
    end

    local id = JN.str(comic._id) or JN.str(comic.id) or JN.num(comic._id) or JN.num(comic.id)

    return {
        _id = id and tostring(id) or "",
        title = JN.str(comic.title) or "未知标题",
        author = JN.str(comic.author) or "未知作者",
        thumb = thumb_url,
        tags = tags,
        pagesCount = JN.num(comic.pagesCount, JN.num(comic.pages, 0)),
        epsCount = JN.num(comic.epsCount, 0),
        finished = JN.bool(comic.finished),
        likesCount = JN.num(comic.likesCount, JN.num(comic.totalLikes, 0)),
        viewsCount = JN.num(comic.viewsCount, JN.num(comic.totalViews, 0)),
        categories = JN.str_list(comic.categories),
        description = JN.str(comic.description, ""),
        chineseTeam = JN.str(comic.chineseTeam, ""),
        -- 列表与详情都返回 updated_at (ISO 串); 以前没接, 卡片与详情页都没有
        -- "更新时间"这一项 (三个源里只有源 C 显示了它)。
        update_time = date_only(comic.updated_at),
        -- **收藏状态必须带上**。列表接口不返回 isFavourite (只有收藏列表接口的条目
        -- 才被 util/favorites.markAll 补成"已收藏"), 所以详情页靠"问源"这一次来
        -- 拿到真实状态 (ui/common/comic_detail.lua:syncFavoriteStateFromSource)。
        -- 这里漏掉它, 那条路径就永远拿到 nil, 直接 return —— 表现是**已收藏的漫画
        -- 从搜索/排行榜/分类进去都显示成「收藏」** (用户报的就是这个)。
        -- 字段名以 docs/05_API参考手册.md 的 /comics/{id} 响应为准。
        isFavourite = JN.bool(comic.isFavourite),
    }
end

--- 提取漫画列表 (标准分页格式)
local function extractComicList(data)
    if not data or not data.data then return nil end
    local comics_raw = nil
    local total, page, pages = 0, 1, 1

    -- 标准: data.comics.docs
    --
    -- total/page/pages 必须是 **number**: 源会把它们当字符串 ("2") 返回, 也可能给 JSON
    -- null (rapidjson 解成真值 userdata, `x or 1` 挡不住)。下游 (列表补货 / 页脚) 会拿
    -- 它们做比较 —— v0.8.6 的"点返回闪退"就是 `number < string` 在 scheduleIn 任务里炸。
    -- 与 JM 源一致, 在源这一层就清洗干净, 不指望每个消费方都记得 tonumber。
    if type(data.data.comics) == "table" and type(data.data.comics.docs) == "table" then
        comics_raw = data.data.comics.docs
        total = JN.num(data.data.comics.total, #comics_raw)
        page = JN.num(data.data.comics.page, 1)
        pages = JN.num(data.data.comics.pages, 1)

    -- 数组: data.comics 直接是数组
    elseif data.data.comics and type(data.data.comics) == "table" and #data.data.comics > 0 then
        comics_raw = data.data.comics
        total = #comics_raw
        pages = 1

    -- 遍历 data 找数组
    elseif type(data.data) == "table" then
        for k, v in pairs(data.data) do
            if type(v) == "table" and #v > 0 and v[1] and (v[1].title or v[1]._id) then
                comics_raw = v
                total = #v
                pages = 1
                if logger.enabled then logger.dbg("PicacgAPI: 从 data." .. k .. " 提取漫画列表") end
                break
            end
        end
    end

    if not comics_raw then return nil end

    local comics = {}
    for _, c in ipairs(comics_raw) do
        local nc = normalizeComic(c)
        if nc then table.insert(comics, nc) end
    end

    return {
        comics = comics,
        total = total,
        page = page,
        pages = pages,
    }
end

-- 无分类 ID 的条目是网页/特殊推荐入口, 不能传给分类搜索接口。
-- 缓存命中也要过滤, 升级后无需等待旧分类缓存过期。
local function comicCategories(categories)
    local result = {}
    for _, category in ipairs(categories) do
        if type(category) == "table" and JN.str(category._id)
                and category._id ~= "" and not JN.bool(category.isWeb)
                and category.active ~= false then
            result[#result + 1] = category
        end
    end
    return result
end

--- 获取分类
function PicacgAPI:getCategories(http_client, headers, auth)
    local cache_key = "picacg_categories"
    local cached = cache:getData(cache_key)
    if cached then return true, comicCategories(cached) end

    local data = self:request(http_client, headers, auth, "GET", "categories")
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取分类失败" end

    local categories = {}
    if data.data and data.data.categories then
        categories = data.data.categories
    elseif type(data.data) == "table" then
        for _, v in pairs(data.data) do
            if type(v) == "table" then
                for _, item in ipairs(v) do
                    if type(item) == "string" then
                        table.insert(categories, item)
                    end
                end
            end
        end
    end

    categories = comicCategories(categories)
    cache:cacheData(cache_key, categories, os.time() + CACHE_TTL.CATEGORIES)
    return true, categories
end

--- 获取漫画列表 (首页推荐)
function PicacgAPI:getComics(http_client, headers, auth, page, sort)
    page = page or 1
    sort = sort or "dd"
    local cache_key = "picacg_comics_" .. page .. "_" .. sort
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics?page=" .. page .. "&s=" .. sort
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取漫画列表失败" end

    local result = extractComicList(data)
    if not result then
        return false, nil, "漫画列表数据格式异常"
    end

    cache:cacheData(cache_key, result, os.time() + CACHE_TTL.COMICS)
    return true, result
end

--- 把分类 id 解析为分类标题
-- 重要: 源 A 的 advanced-search 接口接收的是分类"标题"(如 "短篇")，
-- 传 _id 会返回 200 但结果为空 (曾导致所有分类都显示"没有漫画")。
-- UI 层传的是 id，这里做一次映射 (分类列表有缓存，开销很低)。
-- @return: 分类标题, 或原值 (无法解析时)
function PicacgAPI:resolveCategoryName(http_client, headers, auth, category)
    if category == nil then return nil end
    local s = tostring(category)
    if s == "" then return s end

    -- ObjectId 形如 24 位十六进制
    if not s:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
        return s
    end

    local ok, cats = self:getCategories(http_client, headers, auth)
    if ok and type(cats) == "table" then
        for _i, c in ipairs(cats) do
            if tostring(c._id) == s then
                return c.title
            end
        end
    end
    return s
end

--- 获取分类下的漫画
-- 分类浏览与搜索共用 comics/advanced-search，注意两点:
--   1. categories 要传分类"标题"而非 id
--   2. page 必须放在查询串 (?page=N), 放在 body 里会被服务端忽略
function PicacgAPI:getCategoryComics(http_client, headers, auth, category, page, sort)
    page = page or 1
    sort = sort or "dd"

    local category_name = self:resolveCategoryName(http_client, headers, auth, category)
    if not category_name then
        return false, nil, "无效的分类"
    end

    local cache_key = "picacg_cat_v2_" .. category_name .. "_" .. page .. "_" .. sort
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/advanced-search?page=" .. page
    local body = json.encode({
        keyword = "",
        sort = sort,
        categories = { category_name },
    })

    local data = self:request(http_client, headers, auth, "POST", path, body)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取分类漫画失败" end

    local result = extractComicList(data)
    if not result then return false, nil, "分类漫画数据格式异常" end

    cache:cacheData(cache_key, result, os.time() + CACHE_TTL.COMICS)
    return true, result
end

--- 搜索漫画
function PicacgAPI:search(http_client, headers, auth, keyword, page, sort, categories)
    page = page or 1
    sort = sort or "dd"
    local cache_key = "picacg_search_" .. keyword .. "_" .. page .. "_" .. sort
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    -- 注意: page 必须放在查询串, 放 body 里会被服务端忽略 (分页失效)
    local path = "comics/advanced-search?page=" .. page
    local body = json.encode({
        keyword = keyword,
        sort = sort,
        categories = categories or {},
    })

    local data = self:request(http_client, headers, auth, "POST", path, body)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "搜索失败" end

    local result = extractComicList(data)
    if not result then return false, nil, "搜索结果数据格式异常" end

    cache:cacheData(cache_key, result, os.time() + CACHE_TTL.SEARCH)
    return true, result
end

--- 获取随机漫画
function PicacgAPI:getRandom(http_client, headers, auth, page)
    page = page or 1
    local cache_key = "picacg_random_" .. page
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/random?page=" .. page
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取随机漫画失败" end

    local result = extractComicList(data)
    if not result then
        result = { comics = {}, total = 0, page = page, pages = 1 }
    end

    cache:cacheData(cache_key, result, os.time() + CACHE_TTL.COMICS)
    return true, result
end

--- 获取漫画详情
function PicacgAPI:getComicDetail(http_client, headers, auth, comic_id)
    local cache_key = "picacg_detail_" .. comic_id
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/" .. comic_id
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取详情失败" end

    -- comic 缺失 / 为 JSON null (userdata, `or {}` 挡不住) / 不是表: 判失败。
    -- 旧写法会造出一条 _id="" 的"详情"并缓存一天 (之后每次进来都是空白详情);
    -- comic 为 null 时 normalizeComic 返回 nil, 下一行索引 nil 直接抛异常。
    local detail = type(data.data) == "table" and type(data.data.comic) == "table"
        and normalizeComic(data.data.comic) or nil
    if not detail or detail._id == "" then
        return false, nil, "详情数据格式异常"
    end
    detail.description = detail.description or "暂无描述"
    detail.chineseTeam = detail.chineseTeam or ""

    cache:cacheData(cache_key, detail, os.time() + CACHE_TTL.DETAIL)
    return true, detail
end

--- 获取章节列表
function PicacgAPI:getEpisodes(http_client, headers, auth, comic_id, page)
    page = page or 1
    local cache_key = "picacg_eps_" .. comic_id .. "_" .. page
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/" .. comic_id .. "/eps?page=" .. page
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取章节失败" end

    local eps = { episodes = {}, total = 0, page = page, pages = 1 }
    if data.data and type(data.data.eps) == "table" then
        -- docs 可能是 JSON null (userdata): 下游对它 ipairs / # 都会炸, 用 JN.list 过滤
        eps.episodes = JN.list(data.data.eps.docs)
        eps.total = JN.num(data.data.eps.total, #eps.episodes)
        eps.page = JN.num(data.data.eps.page, page)
        eps.pages = JN.num(data.data.eps.pages, 1)
    end

    cache:cacheData(cache_key, eps, os.time() + CACHE_TTL.EPISODES)
    return true, eps
end

-- ============================================================================
-- 图片地址: 图片代理 缩略图 -> 原图
-- ============================================================================

--- 图片代理 地址里那一段 base64 就是原图地址
--
-- 2026-10-18 真机实测 (抓的是 章节图片接口 的真实响应):
--   media.path 已经**不是**静态文件路径, 而是源 A 自己的 图片代理 签名地址:
--     <fs>带缩放的签名图片地址
--   直接下它拿到的是**服务端缩放到 800 的缩略图**:
--     缩略图 566x800 / 66KB   原图 1200x1695 / 480KB
--   源 C 给的是原图 (1444x2048), 所以"源 A 比源 C 糊" —— 根因不在解码,
--   而在我们下的本来就不是原图。
--
-- 图片代理 的 rs:fit 参数在签名里, 改不了; 但 g:ce 之后那一段就是原图地址本身,
-- 解出来直接请求静态文件即可 (实测 200, 且不需要任何签名头)。
--
-- @param url 接口给的地址 (可能本来就是普通静态地址, 这时原样返回)
-- @return 原图地址 或 nil (不是 图片代理 形式 / 解不出来)
function PicacgAPI.originalImageUrl(url)
    if type(url) ~= "string" or url == "" then return nil end
    if not url:find("/tobeimg/", 1, true) then return nil end

    -- 取最后一段, 去掉 .jpg (扩展名是 图片代理 按输出格式加的, 原图可能是 png)
    local tail = url:match("([^/]+)$")
    if not tail then return nil end
    tail = tail:gsub("%.[%a]+$", "")
    if tail == "" then return nil end

    -- 这段是 base64url (含 - 和 _), 且经常缺 '=' 填充
    tail = tail:gsub("%-", "+"):gsub("_", "/")
    local ok, decoded = pcall(B64.decode, tail)
    if not ok or type(decoded) ~= "string" then return nil end
    if not decoded:match("^https?://") then return nil end
    return decoded
end

--- 该不该下原图 (图片质量设置)
--
-- 源 A 的图片有两档可选: 服务端缩略图 (图片代理, ~800px) 与**原图**。
-- 中间档拿不到 —— 缩放参数在签名里。所以设置项只有两档 (见 ui/settings/reading.lua)。
-- 旧配置里的 medium / high 一律按原图处理 (high 以前写进 image-quality 头,
-- 但那个头对图床无效, 等于什么都没做)。
function PicacgAPI.preferOriginal()
    local q = config:get("image_quality")
    return q ~= "low"
end

--- 获取章节图片 (单页)
function PicacgAPI:getEpisodeImages(http_client, headers, auth, comic_id, order, page)
    page = page or 1
    -- 画质进缓存键: 图片列表里存的已经是**解析好的最终地址** (原图 / 图片代理 缩略图),
    -- 而列表要缓存 1 小时。不带画质的话, 用户切到「缩略图」后再进同一话, 拿到的还是
    -- 上一小时的原图地址 —— 表现就是"这个设置没用"。带上之后切换立刻生效, 切回去
    -- 也还能命中原来那份。
    local quality_tag = PicacgAPI.preferOriginal() and "orig" or "thumb"
    local cache_key = "picacg_images_" .. comic_id .. "_" .. order .. "_" .. page
        .. "_" .. quality_tag
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/" .. comic_id .. "/order/" .. order .. "/pages?page=" .. page
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取图片失败" end

    local images_data = { images = {}, pages = 1, page = page, total = 0 }
    if data.data and type(data.data.pages) == "table" then
        local pages_data = data.data.pages
        images_data.pages = JN.num(pages_data.pages, 1)
        images_data.page = JN.num(pages_data.page, page)
        images_data.total = JN.num(pages_data.total, 0)

        if type(pages_data.docs) == "table" then
            for i, doc in ipairs(pages_data.docs) do
                if type(doc) == "table" and type(doc.media) == "table" and doc.media.path then
                    local url = (doc.media.fileServer or "") .. "/static/" .. (doc.media.path or "")
                    -- 默认下原图; 只有用户显式选了「低」才用服务端缩略图
                    -- (见 PicacgAPI.originalImageUrl 的实测数据)
                    if PicacgAPI.preferOriginal() then
                        url = PicacgAPI.originalImageUrl(url) or url
                    end
                    table.insert(images_data.images, {
                        _id = doc._id or ("image_" .. i),
                        url = url,
                        index = i,
                    })
                end
            end
        end
    end

    cache:cacheData(cache_key, images_data, os.time() + CACHE_TTL.IMAGES)
    return true, images_data
end

--- 获取章节所有图片 (自动分页)
function PicacgAPI:getAllEpisodeImages(http_client, headers, auth, comic_id, order)
    local ok, first_page = self:getEpisodeImages(http_client, headers, auth, comic_id, order, 1)
    if not ok or not first_page or not first_page.images or #first_page.images == 0 then
        return false, nil, "获取图片失败"
    end

    local total_pages = first_page.pages or 1
    if total_pages <= 1 then
        first_page.total_pages = 1
        return true, first_page
    end

    local all_images = {
        images = {},
        total_pages = total_pages,
    }
    for _, img in ipairs(first_page.images) do
        table.insert(all_images.images, img)
    end

    for p = 2, total_pages do
        local p_ok, p_data, p_err = self:getEpisodeImages(http_client, headers, auth, comic_id, order, p)
        if p_ok and p_data and p_data.images then
            for _, img in ipairs(p_data.images) do
                table.insert(all_images.images, img)
            end
        else
            -- 中间某页取失败: **整体报失败**, 不返回残缺列表。
            -- 旧实现 warn + break 后仍返回成功, 后果是两头都错:
            --   * 下载: 把只有前几页的章节标成"已完成", 缺的页永远补不上;
            --   * 阅读: 章节凭空变短, 读到"最后一页"就弹"读完了/下一话"。
            -- 已取回的页在 getEpisodeImages 里按页缓存, 用户重试几乎零成本。
            logger.warn("PicacgAPI: 第 " .. p .. "/" .. total_pages .. " 页图片列表获取失败: "
                .. tostring(p_err))
            return false, nil, string.format("第 %d/%d 页图片列表获取失败: %s",
                p, total_pages, tostring(p_err or "未知错误"))
        end
    end

    if logger.enabled then logger.info("PicacgAPI: 总共 " .. #all_images.images .. " 张图片") end
    return true, all_images
end

-- ==================== 评论 ====================

--- 获取评论列表
--
-- 注意 page 必须放在**查询串**里: 源 A 的服务端会忽略请求体里的分页参数
-- (与 search/getCategoryComics 同一个坑, 见那边的注释)。
function PicacgAPI:getComments(http_client, headers, auth, comic_id, page)
    page = page or 1
    local cache_key = "picacg_comments_" .. comic_id .. "_" .. page
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/" .. comic_id .. "/comments?page=" .. page
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取评论失败" end

    local comments = { comments = {}, total = 0, page = page, pages = 1 }
    if data.data and type(data.data.comments) == "table" then
        local raw = data.data.comments
        comments.comments = JN.list(raw.docs)
        comments.total = JN.num(raw.total, #comments.comments)
        comments.page = JN.num(raw.page, page)
        comments.pages = JN.num(raw.pages, 1)
    end

    cache:cacheData(cache_key, comments, os.time() + CACHE_TTL.COMMENTS)
    return true, comments
end

--- 获取某条评论的回复
-- 端点与请求体格式同 getComments (同样把 page 放查询串)。
function PicacgAPI:getCommentReplies(http_client, headers, auth, comic_id, comment_id, page)
    page = page or 1
    local cache_key = "picacg_comment_replies_" .. comment_id .. "_" .. page
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/" .. comic_id .. "/comments/" .. comment_id .. "/childrens?page=" .. page
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取回复失败" end

    local replies = { replies = {}, total = 0, page = page, pages = 1 }
    if data.data and type(data.data.comments) == "table" then
        local raw = data.data.comments
        replies.replies = JN.list(raw.docs)
        replies.total = JN.num(raw.total, #replies.replies)
        replies.page = JN.num(raw.page, page)
        replies.pages = JN.num(raw.pages, 1)
    end

    cache:cacheData(cache_key, replies, os.time() + CACHE_TTL.COMMENTS)
    return true, replies
end

--- 获取网络收藏
function PicacgAPI:getFavorites(http_client, headers, auth, page, sort)
    page = page or 1
    sort = sort or "dd"
    local cache_key = "picacg_favs_" .. page .. "_" .. sort
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "users/favourite?page=" .. page .. "&s=" .. sort
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取收藏失败" end

    local result = extractComicList(data)
    if not result then
        result = { comics = {}, total = 0, page = page, pages = 1 }
    end

    cache:cacheData(cache_key, result, os.time() + CACHE_TTL.FAVORITES)
    return true, result
end

-- 平台只有 POST 切换接口。每次先读取未缓存的真实状态，再至多切换一次；
-- 写请求禁止自动重发，超时也只读回确认，避免响应丢失后重试又切回去。
function PicacgAPI:setFavorite(http_client, headers, auth, comic_id, wanted)
    local detail_path = "comics/" .. comic_id
    local function readState()
        local data, err = self:request(http_client, headers, auth, "GET", detail_path)
        if not data then return nil, err end
        if not isOk(data) then return nil, data.message or "无法读取收藏状态" end
        local comic = type(data.data) == "table" and data.data.comic
        if type(comic) ~= "table" or type(comic.isFavourite) ~= "boolean" then
            return nil, "无法确认收藏状态，请刷新详情后重试"
        end
        return comic.isFavourite
    end
    local current, err = readState()
    if current == nil then return false, err end
    if current == wanted then
        cache:clear("picacg_detail_" .. comic_id)
        cache:clearPattern("picacg_favs_")
        return true
    end
    local path = "comics/" .. comic_id .. "/favourite"
    local data, write_err = self:request(http_client, headers, auth, "POST", path, "{}", true)
    -- 无论响应是否收到，服务端都可能已完成切换，不再信任旧缓存。
    cache:clear("picacg_detail_" .. comic_id)
    cache:clearPattern("picacg_favs_")
    local now = readState()
    if now == wanted then return true end
    if now == nil then return false, "无法确认收藏结果，请刷新详情后重试" end
    if not data then return false, write_err end
    return false, not isOk(data) and data.message or "收藏状态未更新，请刷新详情后重试"
end

function PicacgAPI:addFavorite(http_client, headers, auth, comic_id)
    return self:setFavorite(http_client, headers, auth, comic_id, true)
end

function PicacgAPI:removeFavorite(http_client, headers, auth, comic_id)
    return self:setFavorite(http_client, headers, auth, comic_id, false)
end

--- 获取排行榜
-- 服务端对该接口的参数校验很严格 (缺参会返回 validation error):
--   ct 必填，取值 VC / CC
--   tt 必填，取值 H24 / D7 / D30
--   page 不被接受 (一次返回约 40 条，无分页)
-- @param rank_type: 时间维度 "H24"/"D7"/"D30"
function PicacgAPI:getRanking(http_client, headers, auth, rank_type, page)
    rank_type = rank_type or "H24"
    local cache_key = "picacg_rank_" .. rank_type
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "comics/leaderboard?ct=VC&tt=" .. rank_type
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取排行榜失败" end

    local result = extractComicList(data)
    if not result then
        result = { comics = {}, total = 0, page = 1, pages = 1 }
    end
    -- 该接口无分页
    result.page = 1
    result.pages = 1

    cache:cacheData(cache_key, result, os.time() + CACHE_TTL.RANKING)
    return true, result
end

--- 获取搜索热词
function PicacgAPI:getSearchKeywords(http_client, headers, auth)
    local cache_key = "picacg_keywords"
    local cached = cache:getData(cache_key)
    if cached then return true, cached end

    local path = "search/leaderboard"
    local data = self:request(http_client, headers, auth, "GET", path)
    if not data then return false, nil, "网络请求失败" end
    if not isOk(data) then return false, nil, data.message or "获取热词失败" end

    local keywords = {}
    if data.data and data.data.keywords then
        keywords = data.data.keywords
    end

    cache:cacheData(cache_key, keywords, os.time() + CACHE_TTL.CATEGORIES)
    return true, keywords
end

return PicacgAPI
