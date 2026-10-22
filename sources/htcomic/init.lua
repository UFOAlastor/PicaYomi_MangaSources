local ctx = assert(ctx, "source SDK context required")
-- source/htcomic/init.lua
-- 源 C (源站) 漫画源入口
-- 实现 ComicSource 基类接口
--
-- 与源 A/源 B 的差异:
--   * 站点是 HTML 页面, 数据靠 htmlparser 解析 (见 api.lua)
--   * 浏览 / 搜索 / 阅读**不需要登录**; 登录只影响收藏夹 (见 requires_login)
--   * 普通作品: 一个相册即一个"章节" (order 固定为 1), 整章图片在一个 gallery 页里
--   * 合集作品: 详情页列出各话 (每话是独立相册, 有各自的 id)。合集自己的 gallery
--     页没有图片, 所以取图前必须把话号换成该话的相册 id (见 _albumIdFor)
--   * 有排行榜: 站点的"收藏排行榜" (今日/本週/本月/今年), 见 getRankings

local logger = ctx.logger
local _ = ctx.translate
local ComicSource = require("object")
local HtAPI = require("api")
local Headers = require("headers")
local HttpClient = ctx.http

local HtComicSource = ComicSource:extend{
    name = "绅士漫画",
    identifier = "htcomic",
    version = "1.0.0",

    capabilities = {
        -- 支持登录, 但**不要求**登录: 免登录源, 首页不该被登录框拦住
        -- (requires_login 是"不登录就用不了"的源才为 true, 见 ui/home.lua)
        login = true,
        requires_login = false,
        search = true,
        latest = true,
        categories = true,
        rankings = true,      -- 收藏排行榜 (今日/本週/本月/今年)
        random = false,
        favorites = false,    -- 网络收藏 (需登录, 未实现)
        comments = false,
        download = true,
        local_favorites = true,
    },
}

--- 初始化
function HtComicSource:init()
    self._http_client = HttpClient
    self._headers = Headers
end

function HtComicSource:_ensureInit()
    if not self._http_client then
        self:init()
    end
end

-- ==================== 账号 ====================

--- 登录 (只影响收藏夹; 浏览/阅读不需要登录)
function HtComicSource:login(username, password)
    return require("auth"):login(username, password)
end

function HtComicSource:logout()
    require("auth"):logout()
end

function HtComicSource:isLoggedIn()
    return require("auth"):isLoggedIn()
end

function HtComicSource:getToken()
    -- 站点没有 token 概念, 会话在 Cookie 里; 这里只用来表达"登录与否"
    return self:isLoggedIn() and "htcomic-session" or nil
end

function HtComicSource:getUserProfile()
    return require("auth"):getUserProfile()
end

-- ==================== 浏览 ====================

--- 首页列表 ("最新")
function HtComicSource:getComics(page, _sort)
    self:_ensureInit()
    return HtAPI:getList(self._http_client, "albums", page)
end

--- 排行榜类型 (站点只有"收藏榜", 用时间维度分档)
function HtComicSource:getRankingTypes()
    return {
        { id = "day",   title = _("今日收藏榜") },
        { id = "week",  title = _("本周收藏榜") },
        { id = "month", title = _("本月收藏榜") },
        { id = "year",  title = _("今年收藏榜") },
    }
end

--- 排行榜某一页
function HtComicSource:getRankings(rtype, page)
    self:_ensureInit()
    return HtAPI:getRanking(self._http_client, rtype, page)
end

function HtComicSource:getCategories()
    self:_ensureInit()
    return HtAPI:getCategories(self._http_client)
end

--- 分类浏览 (category 为 parseCategories 给出的 _id, 即站点的路径名)
function HtComicSource:getCategoryComics(category, page, _sort)
    self:_ensureInit()
    if not category or category == "" then
        return false, nil, "无效的分类"
    end
    return HtAPI:getList(self._http_client, category, page)
end

function HtComicSource:search(keyword, page, _sort)
    self:_ensureInit()
    if not keyword or keyword == "" then
        return false, nil, "请输入关键词"
    end
    return HtAPI:search(self._http_client, keyword, page)
end

function HtComicSource:getComicDetail(comic_id)
    self:_ensureInit()
    return HtAPI:getComicDetail(self._http_client, comic_id)
end

-- ==================== 章节 ====================
-- 一个相册即一个章节

function HtComicSource:getChapters(comic_id, _page)
    self:_ensureInit()

    local ok, detail, err = HtAPI:getComicDetail(self._http_client, comic_id)
    if not ok then
        return false, nil, err
    end

    -- 合集 (多话): 每一话是一个独立相册, 有自己的 id。
    -- 记住"话号 -> 相册 id", 取图时才能换成正确的 gallery 页 —— 合集本身的
    -- gallery 页没有图片。
    local chapters = detail.chapters or {}
    if #chapters > 0 then
        self._series = self._series or {}
        local map = {}
        local episodes = {}
        for _i, ch in ipairs(chapters) do
            local order = tonumber(ch.order) or (#episodes + 1)
            map[order] = ch.id
            episodes[#episodes + 1] = {
                _id = ch.id,
                title = ch.title,
                order = order,
                pagesCount = ch.pages,
            }
        end
        self._series[tostring(comic_id)] = map
        return true, {
            episodes = episodes,
            total = #episodes,
            page = 1,
            pages = 1,
        }
    end

    return true, {
        episodes = {
            {
                title = detail.title,
                order = "1",
                pagesCount = detail.pagesCount,
            },
        },
        total = 1,
        page = 1,
        pages = 1,
    }
end

--- 这一话对应的相册 id
--
-- 单本作品就是它自己; 合集要换成该话的相册 id。映射是 getChapters 建的内存表,
-- 阅读器重启/下载子进程里可能没有 —— 那就重新拉一次详情页重建 (详情页有缓存,
-- 通常不额外发请求)。
function HtComicSource:_albumIdFor(comic_id, chapter_order)
    local key = tostring(comic_id)
    local map = self._series and self._series[key]
    if not map then
        local ok = self:getChapters(comic_id)
        map = ok and self._series and self._series[key] or nil
    end
    local order = tonumber(chapter_order)
    local id = map and order and map[order]
    return id or key
end

function HtComicSource:getChapterImages(comic_id, chapter_order, _page)
    return self:getAllChapterImages(comic_id, chapter_order)
end

function HtComicSource:getAllChapterImages(comic_id, chapter_order)
    self:_ensureInit()
    local album_id = self:_albumIdFor(comic_id, chapter_order)
    return HtAPI:getChapterImages(self._http_client, album_id)
end

-- ==================== 图片下载 ====================

--- 图片请求头 (图片 CDN 校验 Referer)
function HtComicSource:imageHeaders(url)
    self:_ensureInit()
    return Headers:imageHeaders(url)
end

--- 下载单张图片 (图片 CDN 校验 Referer)
function HtComicSource:downloadImage(url, dest_path, timeout)
    if not url or not dest_path then
        return nil, "缺少参数"
    end
    local h, herr = self:imageHeaders(url)
    if not h then
        return nil, herr
    end
    -- 同步下载: 超时越长界面冻结越久
    return self._http_client:download(url, dest_path, h, timeout or 20)
end

function HtComicSource:getLatest(page, sort) return self:getComics(page, sort) end

return HtComicSource
