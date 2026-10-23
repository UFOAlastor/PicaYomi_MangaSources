local ctx = assert(ctx, "source SDK context required")
-- source/htcomic/api.lua
-- 内置源 C 的页面解析与取数
--
-- 该源以 HTML 页面为主，数据靠 KOReader 自带的 htmlparser (CSS 选择器) 解析。
-- 页面结构、选择器与分页规则都封装在本文件的 parse* 函数里；外部只依赖
-- 归一化后的数据结构，不要直接读 HTML 节点。
--
-- 约定:
--   * 列表、分类、搜索、详情、章节各自有独立的解析函数；
--   * 解析失败返回 nil + 可展示的原因，不要返回半成品；
--   * 页面结构变化时只改对应解析函数，保持对外字段不变。

local logger = ctx.logger
local cache = ctx.cache
local _ = ctx.translate
local Headers = require("headers")

-- htmlparser 默认循环上限较低, 大页面会被截断, 必须提高 (parse 时读取该全局量)
htmlparser_opts = { looplimit = 2000000, silent = true }
local htmlparser = ctx.html

local HtAPI = {}

HtAPI.BASE_URL = Headers.BASE_URL

--- 分类缓存的键与时长
--
-- 分类导航是站点级的 (每个页面都一样), 一天一次足够。不缓存的话每次进「分类浏览」
-- 都要多花一个 RTT —— 而它现在是一个真实网络请求了 (见 parseCategories 的说明)。
local CATEGORIES_CACHE_KEY = "htcomic_categories"
local CATEGORIES_CACHE_TTL = 86400

-- ============================================================================
-- 工具
-- ============================================================================

--- 剥标签 + 解 HTML 实体
--
-- 单独抽出来是因为**属性值里也有实体**: 列表项的标题优先取 `a[title]`
-- (比 textonly 干净, 不受内部 <em> 影响), 但那是原始属性值, 不解的话
-- 菜单里会显示成 "[Aster C]&nbsp;&nbsp;ショタ勇者"。
local function unescape(t)
    t = tostring(t or "")
    t = t:gsub("<[^>]*>", "")
    t = t:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 读取节点纯文本 (剥标签与实体)
local function node_text(node)
    if not node then return "" end
    local t
    local ok = pcall(function() t = node:textonly() end)
    if not ok or not t or t == "" then
        pcall(function() t = node:gettext() end)
    end
    return unescape(t)
end

local function parse_html(html)
    if not html or html == "" then return nil end
    local ok, doc = pcall(htmlparser.parse, html)
    if not ok or not doc then
        logger.err("Picayomi HtAPI: HTML 解析失败: " .. tostring(doc))
        return nil
    end
    return doc
end

--- URL 编码 (站点是 UTF-8, 按字节百分号编码即可)
local function urlencode(s)
    return (tostring(s or ""):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- 发起 GET 请求并返回响应体
local function http_get(http_client, url, timeout)
    local h = Headers:build(url)
    local resp, err = http_client:get(url, h, timeout or 20)
    if not resp then
        return nil, "网络请求失败: " .. tostring(err)
    end
    if resp.status_code and resp.status_code >= 400 then
        return nil, "HTTP " .. tostring(resp.status_code)
    end
    return tostring(resp.body or "")
end

--- 列表页的 URL (第 N 页)
-- 实测: /albums.html -> /albums-index-page-2.html
--       /albums-index-cate-5.html -> /albums-index-page-2-cate-5.html
function HtAPI.listUrl(id, page)
    page = tonumber(page) or 1
    if page <= 1 then
        return "/" .. tostring(id):gsub("^/", "") .. ".html"
    end
    local cate = tostring(id):match("cate%-(%d+)")
    if cate then
        return "/albums-index-page-" .. page .. "-cate-" .. cate .. ".html"
    end
    return "/albums-index-page-" .. page .. ".html"
end

--- 从封面地址取缩略图 (列表页给的是协议相对地址)
local function normalize_thumb(src)
    return Headers:normalizeImageUrl(src)
end

-- ============================================================================
-- 分类
-- ============================================================================

--- 这个节点所属的**顶层菜单名** (向上找到最近的 li, 取其中第一个链接的文字)
--
-- 站点的导航是 `<ul><li><a>同人誌</a><div class="drop_dwon">…子类…</div></li>…`,
-- 父与子用的是同一个 class (onemenulayout), 只能靠"祖上是谁"来分组。
local function top_level_name(node)
    local p = node and node.parent
    while p do
        if p.name == "li" then
            local top = p:select("a")[1]
            local t = top and node_text(top)
            return (t ~= "" and t) or nil
        end
        p = p.parent
    end
    return nil
end

--- 从任一页面里解析分类导航
--
-- **不硬编码分类表**。旧实现写死了 9 个, 而站点实际有 20 个 —— 少了
-- 日語/English/其他/3D漫畫/AI圖集/合集 等整类, 用户根本进不去。
--
-- 命名规则: 站点的子类名在多个父类下**重复** (四个「漢化」、三个「日語」、
-- 三个「English」), 直接列出来分不清是哪个父类下的。所以**只在真的重名时**
-- 才把顶层菜单名拼进去 ("單行本 · 漢化"); 名字唯一的 (CG畫集 / Cosplay / 合集…)
-- 保持原样 —— 站点把 CG畫集/AI圖集/3D漫畫/Cosplay 也塞在同人誌那个下拉里,
-- 无差别加前缀会得到"同人誌 · CG畫集"这种误导性的名字。
--
-- 分类用**站点路径**标识 (不是接口参数), 例如 albums-index-cate-5。
--
-- @return { { _id = <路径名>, title = <显示名> }, ... } 或 nil
function HtAPI.parseCategories(html)
    local doc = parse_html(html)
    if not doc then return nil end

    -- 作用域限定在导航里 (`ul#album_tabs`): 页面别处也有指向分类的链接
    -- (页脚/推荐位), 不限定的话同一个分类会出现两次。
    -- 注意 htmlparser 的 select **不支持逗号列表**, 只能用后代选择器一次拿全:
    -- 顶层 `<a>` 是 li 的直接子元素, 子类是 li > drop_dwon > onemenulayout 里的 a,
    -- 两者都被 "ul#album_tabs a" 覆盖。
    local SELECTOR = "ul#album_tabs a"

    -- 第一遍: 收集 + 数重名
    local found, name_count = {}, {}
    for _i, a in ipairs(doc:select(SELECTOR)) do
        local href = a.attributes and a.attributes.href or ""
        local cate = href:match("^/albums%-index%-cate%-(%d+)%.html$")
        local name = node_text(a)
        if cate and name ~= "" and not found["albums-index-cate-" .. cate] then
            found["albums-index-cate-" .. cate] = { name = name, group = top_level_name(a) }
            name_count[name] = (name_count[name] or 0) + 1
        end
    end

    -- 更新 (/albums.html) 不在分类下拉里, 但它是"最新"入口, 一并列出来
    local cats = { { _id = "albums", title = "最新" } }

    -- 第二遍: 按文档序产出 (select 的结果已按 index 排序)
    for _i, a in ipairs(doc:select(SELECTOR)) do
        local href = a.attributes and a.attributes.href or ""
        local cate = href:match("^/albums%-index%-cate%-(%d+)%.html$")
        local name = node_text(a)
        if cate and name ~= "" then
            local id = "albums-index-cate-" .. cate
            local rec = found[id]
            if rec then
                found[id] = nil -- 去重: 同一个分类只出一次
                local title = name
                if name_count[name] > 1 and rec.group then
                    title = rec.group .. " · " .. name
                end
                table.insert(cats, { _id = id, title = title })
            end
        end
    end

    -- 一个分类都没解析出来 => 页面结构变了, 别把"只剩最新"当成正常结果交上去
    if #cats <= 1 then
        logger.warn("Picayomi HtAPI: 分类导航未解析到任何分类")
        return nil
    end
    return cats
end

--- 取分类列表 (带缓存; 站点导航每个页面都一样, 取一页就够)
function HtAPI:getCategories(http_client)
    local cached = cache:getData(CATEGORIES_CACHE_KEY)
    if cached then return true, cached end

    local html, err = http_get(http_client, Headers:buildUrl("/albums.html"))
    if not html then
        return false, nil, err
    end
    local cats = self.parseCategories(html)
    if not cats then
        return false, nil, "未解析到分类 (页面结构可能已变化)"
    end
    cache:cacheData(CATEGORIES_CACHE_KEY, cats, os.time() + CATEGORIES_CACHE_TTL)
    return true, cats
end

-- ============================================================================
-- 列表
-- ============================================================================

--- 列表页的总页数 (取分页器里出现的**最大页码**)
--
-- 两个坑:
--   1. **不能取"最后一个链接"**。分页器末尾是「後頁>」, 它的文字里没有数字 ——
--      旧实现 `node_text(plinks[#plinks]):match("(%d+)")` 于是永远拿不到页码,
--      pages 停在 1, 列表卡在第一页翻不动。用户看到的就是
--      "单行本-汉化不可能才 24 项目" (页脚只显示"已加载 24 项")。
--   2. 页码要从 **href** 里取, 不是链接文字 —— 文字可能是「後頁」/「末頁」/「Next」。
--
-- 站点两类分页器的地址不同, 都要认:
--   列表/分类: /albums-index-page-694-cate-9.html
--   搜索:      /search/index.php?q=…&p=694&…
local function parse_last_page(doc, selector)
    local max_page = 1
    for _i, a in ipairs(doc:select(selector)) do
        local href = a.attributes and a.attributes.href or ""
        local n = tonumber(href:match("page%-(%d+)"))
            or tonumber(href:match("[?&]p=(%d+)"))
        if n and n > max_page then max_page = n end
    end
    return max_page
end

--- 解析列表页 -> { comics = {...}, pages = N }
function HtAPI.parseComicList(html)
    local doc = parse_html(html)
    if not doc then
        return nil, "页面解析失败"
    end

    local comics = {}
    for _i, li in ipairs(doc:select("div.gallary_wrap > ul.cc > li")) do
        local a = li:select("div.pic_box a")[1]
        local href = a and a.attributes and a.attributes.href
        local id = href and href:match("aid%-(%d+)")
        if id then
            local img = li:select("div.pic_box img")[1]
            local src = img and img.attributes and
                (img.attributes.src or img.attributes["data-src"])
            local ta = li:select("div.info div.title a")[1]
            local title = ""
            if ta then
                -- 优先 title 属性 (比 textonly 干净, 不受内部 <em> 影响), 但它不解实体
                local attr = ta.attributes and ta.attributes.title
                title = attr and unescape(attr) or node_text(ta)
            end
            title = title:gsub("<em>", ""):gsub("</em>", "")
            if title == "" then
                title = "作品 " .. id
            end

            local info = node_text(li:select("div.info div.info_col")[1])
            -- 列表项的 info_col 只有一句统计, 既没有作者也没有分类 —— 以前把它整个
            -- 塞进 categories, 详情页的分类行就成了那段页面文案 (真机反馈)。
            -- 作者/分类只有详情页才有, 由详情页打开时补 (见 ComicDetail:syncFromSource)。
            --
            -- 这句统计有**两种形态**, 对应两种作品:
            --   单本: "25張圖片，創建於2026-10-17"
            --   合集: "11話，更新於2026-10-18 公開漫畫"   <- 没有单一页数
            -- 旧实现只认第一种, 合集于是页数恒为 0, 卡片上什么都不显示
            -- (真机反馈: "有些漫画显示页数, 有些不显示")。合集显示章节数更有意义,
            -- 卡片本来就支持 epsCount -> "11话"。
            local pages = tonumber(info:match("(%d+)%s*張"))
                or tonumber(info:match("(%d+)%s*[Pp]")) or 0
            local episodes = tonumber(info:match("(%d+)%s*[話话]"))
            if episodes then pages = 0 end
            -- 列表项既没有作者也没有分类 (只有详情页有)。卡片第二行空着会与
            -- 源 A/源 B 的卡片长得不一样; 这里把 info_col 里的日期拿出来补位
            -- ("創建於2026-10-17" / "更新於2026-10-18")。
            local date = info:match("(%d%d%d%d%-%d%d%-%d%d)")

            table.insert(comics, {
                _id = id,
                title = title,
                author = "",
                categories = nil,
                description = "",
                thumb = normalize_thumb(src),
                pagesCount = pages,
                epsCount = episodes or 0,
                update_time = date,
            })
        end
    end

    -- 总页数: 分页器里最大的页码 (见 parse_last_page)
    local pages = parse_last_page(doc, "div.f_left.paginator a")

    return { comics = comics, pages = pages }
end

--- 取某一类/某一页的列表 (id 取 parseCategories 给出的 _id, 即站点路径名)
--
-- 关于排序: 站点列表页的"排序"菜单只做一件事 —— 把偏好写进 Cookie
-- Mpic_sortset_album 再 reload (statics/js/common.js 的 sort_setting)。
-- 实测带该 Cookie 直接请求, 返回顺序**完全不变** (换 Cookie 名/加 URL 参数/
-- 绕缓存都试过), 服务端并没有按它排。所以这里不提供排序, 免得放一个点了
-- 没反应的按钮。
function HtAPI:getList(http_client, id, page)
    page = tonumber(page) or 1
    local url = Headers:buildUrl(self.listUrl(id, page))
    local html, err = http_get(http_client, url)
    if not html then
        return false, nil, err
    end
    local data, perr = self.parseComicList(html)
    if not data then
        return false, nil, perr
    end
    data.page = page
    if #data.comics == 0 then
        -- **解析成功但没有条目 = 真的到底了**, 不是错误。
        --
        -- 以前这里返回 false, 理由是"页面结构可能已变化" —— 但列表页把 false 当成
        -- "这一页加载失败", 于是用户翻到最后一页会看到"加载失败"并且再也翻不动。
        -- 页面结构真的变了的话, parseComicList 会返回 nil (上面那条分支),
        -- 与"空页"是两件不同的事。
        if logger.enabled then logger.info(string.format("Picayomi htcomic: 第 %d 页没有条目, 视为到底", page)) end
    end
    return true, data
end

-- ============================================================================
-- 排行榜 (收藏榜)
-- ============================================================================
--
-- 站点只有**一种**榜单: 收藏排行榜, 用时间维度分档 (今日/本週/本月/今年)。
-- 路径规则 (2026-10-17 实测):
--   第 1 页: 收藏排行榜页面              (本週)
--            /albums-favorite_ranking-type-<T>.html     (T = day/week/month/year)
--   第 N 页: /albums-favorite_ranking-page-<N>-type-<T>.html
-- 条目结构与普通列表页完全一致, 所以解析直接复用 parseComicList。
HtAPI.RANKING_TYPES = { "day", "week", "month", "year" }

--- 排行榜地址 (非法 type 一律退回 week, 免得把参数拼进路径)
function HtAPI:rankingUrl(rtype, page)
    page = tonumber(page) or 1
    local t = tostring(rtype or "week")
    local valid = false
    for _i, v in ipairs(self.RANKING_TYPES) do
        if v == t then valid = true break end
    end
    if not valid then t = "week" end

    if page <= 1 then
        if t == "week" then return "/albums-favorite_ranking.html" end
        return "/albums-favorite_ranking-type-" .. t .. ".html"
    end
    return string.format("/albums-favorite_ranking-page-%d-type-%s.html", page, t)
end

--- 取排行榜某一页
-- @param rtype "day" | "week" | "month" | "year"
-- @return ok, { comics = {...}, pages = N, page = N }
function HtAPI:getRanking(http_client, rtype, page)
    page = tonumber(page) or 1
    local url = Headers:buildUrl(self:rankingUrl(rtype, page))
    local html, err = http_get(http_client, url)
    if not html then
        return false, nil, err
    end
    local data, perr = self.parseComicList(html)
    if not data then
        return false, nil, perr
    end
    data.page = page
    if #data.comics == 0 then
        if logger.enabled then logger.info(string.format("Picayomi htcomic: 排行榜(%s) 第 %d 页没有条目, 视为到底",
            tostring(rtype), page)) end
    end
    return true, data
end

--- 搜索 (站点搜索页每页 20 条)
function HtAPI:search(http_client, keyword, page)
    page = tonumber(page) or 1
    local url = Headers:buildUrl("/search/?q=" .. urlencode(keyword) ..
        "&f=_all&s=create_time_DESC&syn=yes")
    if page > 1 then
        url = url .. "&p=" .. page
    end
    local html, err = http_get(http_client, url)
    if not html then
        return false, nil, err
    end
    local data, perr = self.parseComicList(html)
    if not data then
        return false, nil, perr
    end
    data.page = page

    -- 搜索页的分页器只列到第 10 页, 拿不到真实总页数; 但结果数那行给了总条数
    -- ("大約有 13,888 項符合查詢結果"), 除以每页条数就是总页数 —— 比分页器准。
    -- 取两者较大值: 分页器给的至少是"站点确实能翻到的页", 别把它缩小。
    local doc = parse_html(html)
    if doc then
        local result = doc:select("p.result b")[1]
        -- 千位分隔符必须先去掉: "13,888" 直接 match("(%d+)") 只会拿到 "13",
        -- 除以每页 24 条算出来是 1 页 —— 搜索同样翻不动页。
        local total = result and tonumber((node_text(result):gsub(",", "")):match("(%d+)"))
        local per = #data.comics
        if total and per and per > 0 then
            data.pages = math.max(data.pages or 1, math.ceil(total / per))
            -- 顺手把总条数带出去: 列表页脚据此显示"共 N 项"。以前只拿它算页数就丢了,
            -- 于是页脚永远只有"第 N 页 · 已加载 K 项"。
            data.total = total
        end
    end
    return true, data
end

-- ============================================================================
-- 详情
-- ============================================================================

--- 解析详情页 HTML (纯函数, 便于测试)
-- @return { _id, title, author, tags, description, pagesCount, thumb, chapters }
function HtAPI._parseComicDetail(html, comic_id)
    local doc = parse_html(html)
    if not doc then
        return nil, "页面解析失败"
    end

    local title = node_text(doc:select("div.userwrap h2")[1])
    if title == "" then
        -- 容错: 少数作品页解析不出标题(版式不同 / 内容受限)。
        -- 不要因此判死整个详情页 —— gallery 页与详情页是独立的,
        -- 降级后用户往往仍能正常阅读。
        logger.warn("Picayomi HtAPI: 详情页未解析到标题, 降级处理 id=" ..
            tostring(comic_id))
        title = "作品 " .. tostring(comic_id)
    end

    -- 封面 (详情页封面在 uwthumb 里)
    local cover_img = doc:select("div.asTBcell.uwthumb img")[1]
    local cover = cover_img and cover_img.attributes and cover_img.attributes.src
    cover = normalize_thumb(cover)

    -- 分類 / 頁數 / 編號
    --
    -- 详情页的这三项都是 <label>: "分類：同人誌／日語" / "頁數：20P" / "編號：源站251279"
    -- (2026-10-18 抓的页面实测)。
    --
    -- **分类必须取「分類」这一项**: 以前把 a.tagshow 的标签串当成 categories,
    -- 于是一行里挤着十几个标签 (かなミ, FUTA, 扶他, hololive…), 真机上被截断,
    -- 看起来就是"分类没东西"。标签是"標籤", 不是分类。
    local pages_count = 0
    local category, comic_no
    local labels = doc:select("div.asTBcell.uwconn label")
    for _i, lb in ipairs(labels) do
        local t = node_text(lb)
        local n = t:match("頁數[：:%.%s]*(%d+)")
        if n then pages_count = tonumber(n) end
        local cat = t:match("^分類[：:%.%s]*(.+)$") or t:match("^分类[：:%.%s]*(.+)$")
        if cat and cat ~= "" then category = cat end
        local no = t:match("編號[：:%.%s]*([%w%-_]+)") or t:match("编号[：:%.%s]*([%w%-_]+)")
        if no and no ~= "" then comic_no = no end
    end

    -- 标签 (必须限定在 div.addtags 里: 合集页的章节链接也用 tagshow 类,
    -- 宽选择器会把"第1話 …"当成标签, 分类那一行会变成一长串章节名)
    local tags = {}
    for _i, a in ipairs(doc:select("div.addtags a.tagshow")) do
        local t = node_text(a)
        if t ~= "" then table.insert(tags, t) end
    end

    -- 简介 (页面里带"簡介："前缀, 详情页自己已有简介区, 去掉避免重复)
    local description = node_text(doc:select("div.asTBcell.uwconn p")[1])
    -- 不能用 [：:] 字符类: Lua 的字符类按**字节**匹配, 会把全角冒号的多字节
    -- 序列吃掉一半 (文字变成乱码)。前缀与冒号分开剥。
    description = description:gsub("^%s*簡介%s*", ""):gsub("^%s*简介%s*", "")
    description = description:gsub("^：%s*", ""):gsub("^:%s*", "")

    -- 上传者
    local uploader = node_text(doc:select("div.asTBcell.uwuinfo a p")[1])

    -- 合集作品: 详情页把各话列成 /photos-slide-aid-<章节id>-sid-<合集id>.html。
    -- **合集自己的 gallery 页是没有图片的** (只返回一句"請加入收藏"的占位),
    -- 所以必须把每一话当成独立相册去读 —— 否则就是用户看到的
    -- "获取漫画图片失败 / 未解析到图片"。
    -- 顺序取标题里的"第N話", 不能按 DOM 顺序: 站点按上传时间排, 与话数不同序。
    local chapters = {}
    for _i, a in ipairs(doc:select("div.sr_compact a.tagshow")) do
        local attrs = a.attributes or {}
        local href = attrs.href or ""
        local chid = href:match("photos%-slide%-aid%-(%d+)%-sid%-") or attrs["data-chid"]
        if chid then
            local title_attr = attrs.title or ""
            local text = node_text(a)
            local order = tonumber(title_attr:match("第(%d+)話"))
                or tonumber(title_attr:match("第(%d+)话"))
                or tonumber(text:match("第(%d+)"))
                or (#chapters + 1)
            table.insert(chapters, {
                id = tostring(chid),
                title = text ~= "" and text or title_attr,
                order = order,
                pages = tonumber(title_attr:match("(%d+)P")),
            })
        end
    end
    table.sort(chapters, function(x, y) return x.order < y.order end)

    -- 编号放到 meta_text 里, 由详情页接在简介后面。
    -- 标签通过 tags 单独显示在可点击的标签栏, 不再重复塞进简介。
    --
    -- **页数不写在这里**: 详情页表头已经统一显示「25页」(与列表卡片同一个
    -- ComicStats.line), 再在简介里写一遍 "25P" 就是同一个数字两种写法。
    local meta_bits = {}
    if comic_no then table.insert(meta_bits, _("编号") .. " " .. comic_no) end
    local meta_text = table.concat(meta_bits, " · ")

    return {
        _id = tostring(comic_id),
        title = title,
        author = uploader,
        tags = tags,
        categories = category or "",
        meta_text = meta_text ~= "" and meta_text or nil,
        description = description,
        pagesCount = pages_count,
        -- 合集没有单一页数, 有章节数: 详情页表头显示「11话」(与列表卡片同一个字段)
        epsCount = #chapters > 0 and #chapters or nil,
        thumb = cover,
        chapters = chapters,
    }
end

--- 漫画详情
-- @return (ok, { _id, title, author, tags, description, pagesCount, thumb, chapters }, err)
function HtAPI:getComicDetail(http_client, comic_id)
    local url = Headers:buildUrl("/photos-index-page-1-aid-" .. tostring(comic_id) .. ".html")
    local html, err = http_get(http_client, url)
    if not html then
        return false, nil, err
    end
    local detail, perr = HtAPI._parseComicDetail(html, comic_id)
    if not detail then
        return false, nil, perr
    end
    return true, detail
end

-- ============================================================================
-- 章节图片
-- ============================================================================

--- 整章图片 (站点把整章图片放在一个 gallery 页里)
-- 图片地址形如协议相对地址 (//host/path)
-- @return (ok, { images = { {url=...}, ... } }, err)
function HtAPI:getChapterImages(http_client, comic_id)
    local url = Headers:buildUrl("/photos-gallery-aid-" .. tostring(comic_id) .. ".html")
    local html, err = http_get(http_client, url)
    if not html then
        return false, nil, err
    end

    -- 图片地址形如 //host/path?verify=<ts>-<sig>
    -- **必须带上 ?verify=... 签名**, 否则 CDN 返回 403「鏈接已失效」。
    -- 地址写在页面的 `document.writeln(... var imglist = [{url: host+"//..."}])` 里,
    -- 故按 "//host/data/..." 匹配到引号 / 反斜杠 / 空白为止。
    -- 排除 /data/t/ (那是列表页的缩略图路径, 不是正文大图)。
    local images = {}
    local seen = {}
    for full in html:gmatch("(//[%w%.%-]+/data/[^%s\"'\\<>]+)") do
        if not full:find("/data/t/", 1, true) then
            local u = "https:" .. full
            if not seen[u] then
                seen[u] = true
                table.insert(images, { url = u })
            end
        end
    end

    if #images == 0 then
        -- 有些作品(受限内容)会跳到登录页, 给用户一个能看懂的提示
        if html:find("登錄", 1, true) or html:find("登入", 1, true)
           or html:find("users-login", 1, true) then
            return false, nil, "该作品需要登录后才能阅读"
        end
        return false, nil, "未解析到图片 (作品可能已失效)"
    end
    return true, { images = images }
end

return HtAPI
