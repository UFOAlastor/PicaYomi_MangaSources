local ctx = assert(ctx, "source SDK context required")
-- source/htcomic/headers.lua
-- 内置源 C 的请求头与 Cookie 管理
--
-- 浏览 / 搜索 / 阅读不需要登录；登录只影响收藏类功能。
-- Cookie 仅在需要会话的请求里携带，不要写入日志。

local SecretStore = ctx.secrets

local Headers = {}

Headers.BASE_URL = "https://www.wnacg.com"
Headers.CONFIG_PREFIX = "source.htcomic"
Headers.COOKIE_KEY = Headers.CONFIG_PREFIX .. ".cookies"

-- 站点对 UA 有要求, 用常见桌面浏览器 UA
Headers.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " ..
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

function Headers:getBaseUrl()
    local base = ctx.getSetting("base_url", self.BASE_URL):gsub("/+$", "")
    assert(base:match("^https://[%w%.%-]+$"), "网站地址必须为 HTTPS 域名")
    return base
end

--- 读取已保存的 Cookie (加密存储; 形如 "key=value; key2=value2")
function Headers:getCookieString()
    local c = SecretStore.get(self.COOKIE_KEY)
    if c and c ~= "" then
        return c
    end
    return nil
end

function Headers:setCookieString(s)
    if s == nil or s == "" then
        SecretStore.clear(self.COOKIE_KEY)
        return
    end
    SecretStore.set(self.COOKIE_KEY, s)
end

function Headers:clearCookies()
    SecretStore.clear(self.COOKIE_KEY)
end

-- Set-Cookie 里这些是**属性**, 不是 cookie (值里还带逗号, 例如 Expires 的日期)
local COOKIE_ATTRS = {
    expires = true, path = true, domain = true, ["max-age"] = true,
    samesite = true, secure = true, httponly = true, priority = true,
}

--- 把响应里的 Set-Cookie 合并进已保存的 Cookie 串
--
-- 为什么要自己拼: 我们的 HttpClient 是"请求-响应"式的, 没有 cookie jar
-- (network/http_client.lua 只带我们显式给的 Cookie 头)。登录成功后站点把会话
-- 写在 Set-Cookie 里, 必须自己收下来, 否则下一个请求又是匿名。
--
-- 解析按 "逗号" 粗切: 单个 cookie 的 key=value 一定在第一个分号之前, 之后的
-- 属性 (包括带逗号的 Expires) 一律丢掉, 所以切坏了也不影响结果。
--
-- @param raw string 或 {string} (luasocket 对重复头会拼成 "a, b")
-- @return 是否至少合并进一个 cookie
function Headers:mergeSetCookie(raw)
    if not raw then return false end
    local chunks = type(raw) == "table" and raw or { raw }

    local jar = {}
    local old = self:getCookieString()
    if old then
        for k, v in old:gmatch("([^=;%s]+)=([^;]*)") do
            jar[k] = v
        end
    end

    local added = 0
    for _i, chunk in ipairs(chunks) do
        for piece in tostring(chunk):gmatch("[^,]+") do
            local k, v = piece:match("^%s*([^=;%s]+)=([^;]*)")
            if k and k ~= "" and not COOKIE_ATTRS[k:lower()]
                and k:match("^[%w_%-%.]+$") then
                jar[k] = v
                added = added + 1
            end
        end
    end

    if added == 0 then return false end

    -- 排序后落盘: 同样的 cookie 集合永远得到同一个字符串, 配置里好读也便于测试
    local out = {}
    for k, v in pairs(jar) do out[#out + 1] = k .. "=" .. v end
    table.sort(out)
    self:setCookieString(table.concat(out, "; "))
    return true
end

--- 构造请求头
-- @param url: 目标 URL (用于决定 Referer)
-- @param extra: 额外头 (可选)
function Headers:build(url, extra)
    local h = {
        ["User-Agent"]      = self.USER_AGENT,
        ["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
        ["Referer"]         = self:getBaseUrl() .. "/",
    }

    local cookies = self:getCookieString()
    if cookies then
        h["Cookie"] = cookies
    end

    if extra then
        for k, v in pairs(extra) do
            h[k] = v
        end
    end

    return h
end

--- 图片请求头 (图片 CDN 会校验 Referer)
function Headers:imageHeaders(url)
    local h = self:build(url)
    h["Accept"] = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
    h["Connection"] = "close"
    return h
end

--- 构造完整 URL (支持 //host/path 形式的协议相对地址)
function Headers:buildUrl(path)
    if not path then return nil end
    if path:match("^https?://") then
        return path
    end
    if path:match("^//") then
        return "https:" .. path
    end
    local base = self:getBaseUrl()
    if path:sub(1, 1) == "/" then
        return base .. path
    end
    return base .. "/" .. path
end

return Headers
