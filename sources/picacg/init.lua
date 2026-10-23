local ctx = assert(ctx, "source SDK context required")
-- source/picacg/init.lua
-- 源 A 源入口
-- 实现 ComicSource 基类接口

local logger = ctx.logger
local ComicSource = require("object")
local PicacgAuth = require("auth")
local PicacgAPI = require("api")
local Headers = require("headers")
local HttpClient = ctx.http
local FavoritesUtil = {markAll=function(data) for _,comic in ipairs(data.comics or {}) do comic.isFavourite=true end end}

local PicacgSource = ComicSource:extend{
    name = "哔咔漫画",
    identifier = "picacg",
    version = "1.0.0",

    capabilities = {
        login = true,
        requires_login = true,
        search = true,
        latest = true,
        categories = true,
        rankings = true,
        random = true,
        favorites = true,
        comments = true,
        replies = "paged",
        download = true,
        local_favorites = true,
    },
}

--- 初始化
function PicacgSource:init()
    -- 懒加载: 只在实际使用时创建实例
    self._http_client = HttpClient
    self._headers = Headers
    self._auth = PicacgAuth
    self._api = PicacgAPI
end

--- 确保已初始化
function PicacgSource:_ensureInit()
    if not self._http_client then
        self:init()
    end
end

-- ==================== 认证 ====================

function PicacgSource:login(username, password)
    self:_ensureInit()
    return self._auth:login(username, password, self._http_client, self._headers)
end

function PicacgSource:getToken()
    return PicacgAuth:getToken()
end

function PicacgSource:isLoggedIn()
    return PicacgAuth:isLoggedIn()
end

function PicacgSource:logout()
    PicacgAuth:logout()
end

function PicacgSource:getUserProfile()
    self:_ensureInit()
    return self._auth:getUserProfile(self._http_client, self._headers)
end

function PicacgSource:punchIn()
    self:_ensureInit()
    return self._auth:punchIn(self._http_client, self._headers)
end

-- ==================== 漫画浏览 ====================

function PicacgSource:getCategories()
    self:_ensureInit()
    return self._api:getCategories(self._http_client, self._headers, self._auth)
end

function PicacgSource:getCategoryComics(category, page, sort)
    self:_ensureInit()
    return self._api:getCategoryComics(self._http_client, self._headers, self._auth,
        category, page, sort)
end

function PicacgSource:search(keyword, page, sort, categories)
    self:_ensureInit()
    return self._api:search(self._http_client, self._headers, self._auth,
        keyword, page, sort, categories)
end

function PicacgSource:getRandom(page)
    self:_ensureInit()
    return self._api:getRandom(self._http_client, self._headers, self._auth, page)
end

--- 源 A 的排序能力
-- 推荐/分类/搜索走的是同一套 s= 取值, 所以三类都支持 (实测接口带 s= 生效)
function PicacgSource:getSortOptions(_list_kind)
    -- 取值语义已用真实接口实测确认 (对比漫画 id 前缀 —— 源 A id 前缀即 ObjectId 时间戳):
    --   dd -> 新到旧(按发布时间)     da -> 旧到新
    --   ua -> 最近更新               ld / vd -> 爱心 / 指名数
    -- 此前把 ua 标成"新到旧"、dd 标成"旧到新", **正好写反了** ——
    -- 用户选"旧到新"反而看到最新的作品。
    return {
        { value = "dd", text = "新到旧" },
        { value = "da", text = "旧到新" },
        { value = "ua", text = "最近更新" },
        { value = "ld", text = "最多爱心" },
        { value = "vd", text = "最多绅士指名" },
    }
end

function PicacgSource:getLatest(page, sort) return self:getComics(page, sort) end

function PicacgSource:getRankingTypes()
    return { {id="H24",title="24小时热门"}, {id="D7",title="7天热门"}, {id="D30",title="30天热门"} }
end

function PicacgSource:getComics(page, sort)
    self:_ensureInit()
    return self._api:getComics(self._http_client, self._headers, self._auth, page, sort)
end

function PicacgSource:getComicDetail(comic_id)
    self:_ensureInit()
    return self._api:getComicDetail(self._http_client, self._headers, self._auth, comic_id)
end

function PicacgSource:getChapters(comic_id, page)
    self:_ensureInit()
    return self._api:getEpisodes(self._http_client, self._headers, self._auth, comic_id, page)
end

function PicacgSource:getChapterImages(comic_id, chapter_order, page)
    self:_ensureInit()
    return self._api:getEpisodeImages(self._http_client, self._headers, self._auth,
        comic_id, chapter_order, page)
end

function PicacgSource:getAllChapterImages(comic_id, chapter_order)
    self:_ensureInit()
    return self._api:getAllEpisodeImages(self._http_client, self._headers, self._auth,
        comic_id, chapter_order)
end

function PicacgSource:getRankings(rank_type, page)
    self:_ensureInit()
    return self._api:getRanking(self._http_client, self._headers, self._auth,
        rank_type, page)
end

function PicacgSource:getSearchKeywords()
    self:_ensureInit()
    return self._api:getSearchKeywords(self._http_client, self._headers, self._auth)
end

-- ==================== 收藏 ====================

function PicacgSource:getFavorites(page, sort)
    self:_ensureInit()
    local ok, data, err = self._api:getFavorites(self._http_client, self._headers,
        self._auth, page, sort)
    FavoritesUtil.markAll(data)
    return ok, data, err
end

--- 加入收藏 / 取消收藏: API 层把平台的 POST 切换封装为设定语义。
function PicacgSource:addFavorite(comic_id)
    self:_ensureInit()
    return self._api:addFavorite(self._http_client, self._headers, self._auth, comic_id)
end

function PicacgSource:removeFavorite(comic_id)
    self:_ensureInit()
    return self._api:removeFavorite(self._http_client, self._headers, self._auth, comic_id)
end

function PicacgSource:toggleFavorite(comic_id)
    self:_ensureInit()
    -- 先查当前状态
    local ok, detail = self._api:getComicDetail(self._http_client, self._headers,
        self._auth, comic_id)
    if ok and detail and detail.isFavourite then
        return self._api:removeFavorite(self._http_client, self._headers, self._auth, comic_id)
    else
        return self._api:addFavorite(self._http_client, self._headers, self._auth, comic_id)
    end
end

function PicacgSource:setToken(token)
    return PicacgAuth:setToken(token)
end

function PicacgSource:legacyProfile()
    return ctx.secrets.get_json("profile")
end

-- ==================== 评论 ====================

-- 契约统一为 (ok, data, err) —— 与其余取数方法一致 (旧的裸实现返回 (data, err))。
function PicacgSource:getComments(comic_id, page)
    self:_ensureInit()
    return self._api:getComments(self._http_client, self._headers, self._auth,
        comic_id, page)
end

function PicacgSource:getCommentReplies(comic_id, comment_id, page)
    self:_ensureInit()
    return self._api:getCommentReplies(self._http_client, self._headers, self._auth,
        comic_id, comment_id, page)
end

-- ==================== 图片下载 ====================

--- 图片请求头
--
-- 源 A 的签名含 `ts=os.time()` 与"由图片 URL 推出的 path", 所以**每次都要现算**。
-- 单独抽出来是为了让 fork 出来的下载 worker 也能拿到当下正确的头:
-- 子进程是父进程的快照, 登录 token 刷新后子进程里还是旧值 —— 由父进程在发起那一刻
-- 现算并随任务下发, 就不存在过期问题 (见 source/base.lua 的 imageHeaders 说明)。
-- @return headers 表 或 nil, err
function PicacgSource:imageHeaders(url)
    self:_ensureInit()
    local token = self._auth:getToken()
    local req_headers = self._headers:build(url, "GET", token)
    if not req_headers then
        return nil, "请求头构造失败"
    end
    req_headers["Connection"] = "close"
    req_headers["Accept-Encoding"] = "identity"
    return req_headers
end

--- 下载单张图片
function PicacgSource:downloadImage(url, dest_path, timeout)
    local req_headers, err = self:imageHeaders(url)
    if not req_headers then
        return nil, err
    end
    -- 超时保持较短: 下载是同步的, 超时越长界面冻结越久
    return self._http_client:download(url, dest_path, req_headers, timeout or 15)
end

return PicacgSource
