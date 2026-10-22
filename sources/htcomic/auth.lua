local ctx = assert(ctx, "source SDK context required")
-- source/htcomic/auth.lua
-- 内置源 C 的登录
--
-- 表单登录；成功后会拿到会话 Cookie，后续请求靠它识别身份。
-- 具体表单字段与返回格式封装在本文件内，不要散落到 UI。
--
-- 重要边界:
--   * 浏览/搜索/阅读**不需要登录** —— 登录只影响收藏夹 (requires_login = false,
--     见 source/htcomic/init.lua 的 capabilities)。所以首页不会因为未登录被拦住。
--   * **不落盘密码**。只存站点给的会话 Cookie 和用户名 (与 util/config.lua 的
--     注释同一个约定: 记住登录靠可撤销的 token/cookie, 不是密码)。
--   * 会话过期时, 下一次请求会变成匿名 —— 表现为"收藏突然没了", 重新登录即可。

local Headers = require("headers")
local SecretStore = ctx.secrets
local logger = ctx.logger
local _ = ctx.translate
local json = ctx.json

local HtAuth = {}

-- 账号名 (仅用于界面显示; 判断登录态还要求有 Cookie)
HtAuth.ACCOUNT_KEY = "source.htcomic.account"

--- URL 编码 (站点是 UTF-8, 按字节百分号编码即可)
local function urlencode(s)
    return (tostring(s or ""):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- 剥掉错误提示里的标签/实体 (站点把文案放在 JSON 的 html 字段里)
local function plain_text(s)
    s = tostring(s or "")
    s = s:gsub("<[^>]*>", "")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 是否已登录
--
-- 判据是"有会话 Cookie **且** 记着账号名": 单看 Cookie 不够 —— 站点/CDN 也会
-- 下发匿名 Cookie, 单看账号名也不够 —— 会话可能已经过期。
function HtAuth:isLoggedIn()
    return Headers:getCookieString() ~= nil and SecretStore.get(self.ACCOUNT_KEY) ~= nil
end

--- 登录
-- @return ok, err
function HtAuth:login(username, password)
    username = tostring(username or "")
    password = tostring(password or "")
    if username == "" or password == "" then
        return false, _("请输入用户名和密码")
    end

    local url = Headers:buildUrl("/users-check_login.html")
    local body = table.concat({
        "normal=1",
        "login_name=" .. urlencode(username),
        "login_pass=" .. urlencode(password),
        "remember_pass=1",
        "submit=" .. urlencode("登錄"),
    }, "&")

    local headers = Headers:build(url)
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local resp, err = ctx.http:post(url, headers, body, 20)
    if not resp then
        logger.warn("Picayomi HtAuth: 登录请求失败: " .. tostring(err))
        return false, _("网络请求失败")
    end
    if resp.status_code and resp.status_code >= 400 then
        return false, "HTTP " .. tostring(resp.status_code)
    end

    local text = tostring(resp.body or "")
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" then
        logger.warn("Picayomi HtAuth: 登录返回不是 JSON: " .. text:sub(1, 120))
        return false, _("登录失败（返回格式异常）")
    end

    if not data.ret then
        -- 站点给的文案是繁体, 直接透出比"登录失败"有用
        local msg = plain_text(data.html)
        if logger.enabled then logger.info("Picayomi HtAuth: 登录被拒绝: " .. msg) end
        return false, msg ~= "" and msg or _("用户名或密码错误")
    end

    local got_cookie = Headers:mergeSetCookie(resp.headers and resp.headers["set-cookie"])
    if not got_cookie and not Headers:getCookieString() then
        -- 登录成功却没拿到会话: 后续请求仍是匿名, 当成失败更诚实
        logger.warn("Picayomi HtAuth: 登录成功但没有会话 Cookie")
        return false, _("登录成功但没有拿到会话 Cookie")
    end

    SecretStore.set(self.ACCOUNT_KEY, username)
    if logger.enabled then logger.info("Picayomi HtAuth: 登录成功") end
    return true
end

--- 退出登录 (清 Cookie 与账号名)
function HtAuth:logout()
    Headers:clearCookies()
    SecretStore.clear(self.ACCOUNT_KEY)
    if logger.enabled then logger.info("Picayomi HtAuth: 已退出登录") end
end

--- 用户资料 (站点没有"当前用户"接口, 用登录时记下的用户名)
function HtAuth:getUserProfile()
    if not self:isLoggedIn() then return nil end
    local name = SecretStore.get(self.ACCOUNT_KEY) or ""
    return {
        name = name ~= "" and name or _("绅士漫画用户"),
        username = name,
    }
end

return HtAuth
