local ctx = assert(ctx, "source SDK context required")
-- source/jm/init.lua
-- 源 B (源 B) 源入口
-- 实现 ComicSource 基类接口, 复用统一的列表/详情/阅读 UI
--
-- 注意: ComicSource 的方法契约是 (true, data) / (false, nil, err),
-- 而 source/jm/api.lua 内部用 (data, err)。转换统一放在这一层。

local logger = ctx.logger
local ComicSource = require("object")
local Headers = require("headers")
local Api = require("api")
local HttpClient = ctx.http
local Scramble = require("scramble")
local FavoritesUtil = {markAll=function(data) for _,comic in ipairs(data.comics or {}) do comic.isFavourite=true end end}

local JmSource = ComicSource:extend{
    name = "禁漫天堂",
    identifier = "jm",
    version = "1.0.0",

    capabilities = {
        login = true,
        requires_login = true,
        search = true,
        latest = true,
        categories = true,
        rankings = true,
        random = false,
        favorites = true,
        comments = true,
        replies = "embedded",
        download = true,
        local_favorites = true,
    },
}

-- ==================== 返回约定包装 ====================

--- 把 Api 的 (data, err) 转成源契约的 (ok, data, err)
local function wrap(data, err)
    if not data then
        return false, nil, err or "未知错误"
    end
    return true, data
end

-- ==================== 认证 ====================

-- Cache from 0.9.51 already contains original images. Package extraction does
-- not clear user downloads or reading progress; cache migrations belong to host.
function JmSource:init()
    -- 域名/图片 CDN 都是懒加载, 首次请求时才探测
    -- 先恢复磁盘上的会话 Cookie (加密存储), 再判断登录态
    Api.ensureSessionLoaded()
    self._http_client = HttpClient

end

function JmSource:login(username, password)
    local info, err = Api.login(username, password)
    if not info then
        return false, err or "登录失败"
    end
    return true
end

function JmSource:logout()
    Api.logout()
end

function JmSource:getToken()
    return Api.isLoggedIn() and "jm-session" or nil
end

function JmSource:isLoggedIn()
    return Api.isLoggedIn()
end

function JmSource:getUserProfile()
    if not Api.isLoggedIn() then return nil end
    -- 刚启动时内存里还没有用户名, 用加密存储里的账号名兜底
    local username = Api.username
    if not username or username == "" then
        username = Api.getUsername() or ""
    end
    return {
        name = username ~= "" and username or "禁漫用户",
        username = username,
    }
end

-- ==================== 漫画浏览 ====================

function JmSource:getCategories()
    return wrap(Api.getCategories())
end

--- 源 B 的排序能力
-- 分类与搜索都走 分类筛选接口 或 /search 的 o= 取值; 但
-- **推荐/最新不支持排序** (最新列表接口 没有排序参数), 所以那一类返回空表,
-- 界面据此不显示"排序"按钮 —— 显示了一个点了没反应的按钮比不显示更糟。
function JmSource:getSortOptions(_list_kind)
    -- 推荐/最新 与 分类 用的是同一套排序取值:
    --   mr = 最新列表接口 (App 自己的最新列表, 不接受排序参数)
    --   mv/mp/tf = 分类筛选接口 (全库筛选, 排序真的生效)
    -- 以前 recommend 直接返回空表 —— 于是"推荐/最新"页没有排序按钮。
    return {
        { value = "mr", text = "最新" },
        { value = "mv", text = "总排行" },
        { value = "mp", text = "最多图片" },
        { value = "tf", text = "最多喜欢" },
    }
end

function JmSource:getCategoryComics(category, page, sort)
    return wrap(Api.getCategoryComics(category, page, sort))
end

function JmSource:search(keyword, page, sort)
    return wrap(Api.getSearch(keyword, page, sort))
end

--- 首页“推荐/最新”入口: 源 B 没有随机推荐, 用最新代替 (可排序)
function JmSource:getComics(page, sort)
    return wrap(Api.getLatest(page, sort))
end

function JmSource:getComicDetail(comic_id)
    return wrap(Api.getAlbum(comic_id))
end

function JmSource:getChapters(comic_id, _page)
    return wrap(Api.getChapters(comic_id))
end

function JmSource:getChapterImages(comic_id, chapter_order, _page)
    return wrap(Api.getChapterImages(comic_id, chapter_order))
end

function JmSource:getAllChapterImages(comic_id, chapter_order)
    return wrap(Api.getChapterImages(comic_id, chapter_order))
end

--- 排行榜: 源 B 的排行就是"按排序方式筛选全部作品"
function JmSource:getRankings(rank_type, page)
    return wrap(Api.getCategoryComics("", page, rank_type))
end

function JmSource:getComments(comic_id, page)
    return wrap(Api.getComments(comic_id, page))
end

function JmSource:getRankingTypes()
    return {
        { id = "mv", title = "总排行" },
        { id = "mv_m", title = "月排行" },
        { id = "mv_w", title = "周排行" },
        { id = "mv_t", title = "日排行" },
    }
end

function JmSource:getSearchSortOptions()
    return {
        { id = "mr", title = "最新" },
        { id = "mv", title = "总排行" },
        { id = "mp", title = "最多图片" },
        { id = "tf", title = "最多喜欢" },
    }
end

-- ==================== 收藏 ====================

function JmSource:getFavorites(page, sort)
    local data, err = Api.getFavorites(page, sort)
    FavoritesUtil.markAll(data)
    return wrap(data, err)
end

function JmSource:toggleFavorite(comic_id)
    local ok, err = Api.toggleFavorite(comic_id)
    if not ok then
        return false, err or "操作失败"
    end
    return true
end

--- 加入收藏 / 取消收藏 (设定语义; 源 B 的端点是切换, 由 Api 层兜成设定)
function JmSource:addFavorite(comic_id)
    local ok, err = Api.addFavorite(comic_id)
    if not ok then
        return false, err or "收藏失败"
    end
    return true
end

function JmSource:removeFavorite(comic_id)
    local ok, err = Api.removeFavorite(comic_id)
    if not ok then
        return false, err or "取消收藏失败"
    end
    return true
end

-- ==================== 图片下载 ====================

-- 关于缓存失效判定 (**不再实现 isCachedImageStale**):
--   旧实现靠"扩展名是不是 png"判断缓存是不是解扰前的旧文件 —— 那在"解扰结果
--   一律写成 PNG"的年代成立。0.9.7 起缓存里存的就是源站原图 (webp/jpg), 这条
--   判据会把**每一页**都判成失效: get_local 返回 nil -> 渲染链画占位页 ->
--   再次 request_page -> 下完又被判失效 …… 真机表现是"一张图都不出, 且同一页
--   每秒重下一次" (2026-10-18 现场)。旧格式迁移由宿主显式处理。

--- 图片请求头 (源 B CDN 用常量头, 不含签名, 所以无需每请求现算)
function JmSource:imageHeaders(_url)
    return Headers.imgHeaders()
end

--- 渲染期变换描述符: 正文图做了分带混淆, 解码后必须在内存里还原
--
-- **不再用 imagePost**: 那条路在下载子进程里, 只能"解码 -> 重排 -> 重新编码
-- PNG 覆盖原文件"。真机实测这一步要 3.7~3.9 秒/页 (整页 5.2s), 其中 3.5 秒
-- 是重新压缩一张照片 —— 为了一次内存重排付一次图像编码, 是这条链上最贵的浪费。
-- 现在缓存存原始文件, 渲染时当场重排 (18 次整块搬运, Mac 上 <1ms)。
--
-- 封面走 /media/albums/, 不在此列。


--- 下载单张图片 (封面/正文都走 img_host CDN); **只下载, 不还原**
function JmSource:downloadImage(url, dest_path, timeout)
    if not url or not dest_path then
        return nil, "缺少参数"
    end
    local headers, herr = self:imageHeaders(url)
    if not headers then
        return nil, herr
    end
    -- 同步下载, 超时越长界面冻结越久
    local ok, res = HttpClient:download(url, dest_path, headers, timeout or 15)
    if not ok then
        return ok, res
    end

    -- 这里**只下载, 不还原**。源 B 的分带还原改在渲染期做 (见 imageRenderPost),
    -- 落盘还原就必须重新编码一张照片, 真机 3.5 秒/页 —— 而且这个函数是同步
    -- 回退传输层 (network/transport_blocking.lua) 的下载实现, 还原一次之后渲染期
    -- 还会再还原一次, 画面直接全乱。
    return true, res
end

--- 构造图片 URL (供需要自行拼接的场景)
function JmSource:buildImageUrl(chapter_id, filename)
    return Api.pageUrl(chapter_id, filename)
end

function JmSource:getLatest(page, sort) return self:getComics(page, sort) end

return JmSource
