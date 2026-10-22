local ctx = assert(ctx, "source SDK context required")
-- source/picacg/auth.lua
-- 源 A 认证模块
-- 从 api/auth.lua 迁移

local logger = ctx.logger
local SecretStore = ctx.secrets
local json = ctx.json

local PicacgAuth = {}

-- 配置键前缀
local CONFIG_PREFIX = "source.picacg"
local TOKEN_KEY = CONFIG_PREFIX .. ".token"
local USERNAME_KEY = CONFIG_PREFIX .. ".username"

--- 获取 Token (加密存储; 兼容旧明文的 key)
function PicacgAuth:getToken()
    local token = SecretStore.get(TOKEN_KEY)
    if token and token ~= "" then
        return token
    end
    -- 兼容旧格式 ("token" 明文键由 SecretStore 就地迁移)
    return SecretStore.get("token")
end

--- 设置 Token
function PicacgAuth:setToken(token)
    if token == nil or token == "" then
        SecretStore.clear(TOKEN_KEY)
        SecretStore.clear("token")
        return
    end
    SecretStore.set(TOKEN_KEY, token)
    -- 新版本只写一个键; 旧明文键必须清掉, 否则迁移逻辑会再次见到它
    SecretStore.clear("token")
end

--- 是否已登录
function PicacgAuth:isLoggedIn()
    return self:getToken() ~= nil
end

--- 登录
-- @param username: 用户名/邮箱
-- @param password: 密码
-- @param http_client: HttpClient 实例
-- @param headers: Headers 模块
-- @return: true 或 nil, err
function PicacgAuth:login(username, password, http_client, headers)
    if not username or not password then
        return nil, "用户名和密码不能为空"
    end

    local body = json.encode({
        email = username,
        password = password,
    })

    local path = "auth/sign-in"
    local url = headers:buildUrl(path)
    local req_headers = headers:build(path, "POST", nil)

    if not req_headers then
        return nil, "请求头构造失败"
    end

    if logger.enabled then logger.info("Picayomi SourceAAuth: 登录请求") end

    local response, err = http_client:requestWithRetry("POST", url, req_headers, body, 15)
    if not response then
        return nil, "网络请求失败: " .. tostring(err)
    end

    local data = http_client:parseJsonResponse(response)
    if not data then
        return nil, "响应解析失败"
    end

    if data.code == 200 and data.message == "success" then
        local token = data.data and data.data.token
        if token and token ~= "" then
            self:setToken(token)
            -- 账号名也是 PII, 不写明文
            SecretStore.set(USERNAME_KEY, username)
            if logger.enabled then logger.info("Picayomi SourceAAuth: 登录成功") end
            return true
        end
    end

    local msg = data.message or "登录失败"
    logger.err("Picayomi SourceAAuth: 登录失败: " .. msg)
    return nil, msg
end

--- 退出登录
function PicacgAuth:logout()
    SecretStore.clear(TOKEN_KEY)
    SecretStore.clear("token")
    SecretStore.clear(USERNAME_KEY)
    if logger.enabled then logger.info("Picayomi SourceAAuth: 已退出登录") end
end

--- 获取用户信息
function PicacgAuth:getUserProfile(http_client, headers)
    local token = self:getToken()
    if not token then
        return nil, "未登录"
    end

    local path = "users/profile"
    local url = headers:buildUrl(path)
    local req_headers = headers:build(path, "GET", token)

    local response, err = http_client:get(url, req_headers, 10)
    if not response then
        return nil, "网络请求失败: " .. tostring(err)
    end

    local data = http_client:parseJsonResponse(response)
    if not data then
        return nil, "响应解析失败"
    end

    if data.code == 200 and data.data and data.data.user then
        local user = data.data.user

        -- 规范化用户资料, 统一各源的 profile 字段
        local profile = {
            id = user._id or "unknown_id",
            name = user.name or "未知用户",
            email = user.email or "",
            level = tonumber(user.level) or 1,
            exp = tonumber(user.exp) or 0,
            title = user.title or "",
            slogan = user.slogan or "",
            isPunched = user.isPunched or false,
            character = user.character or "",
        }

        -- 头像地址拼接
        if user.avatar then
            if type(user.avatar) == "table" and user.avatar.fileServer and user.avatar.path then
                profile.avatar = user.avatar.fileServer .. "/static/" .. user.avatar.path
            elseif type(user.avatar) == "string" then
                profile.avatar = user.avatar
            end
        end

        return profile
    end

    return nil, data.message or "获取用户信息失败"
end

--- 打卡
function PicacgAuth:punchIn(http_client, headers)
    local token = self:getToken()
    if not token then
        return nil, "未登录"
    end

    local path = "users/punch-in"
    local url = headers:buildUrl(path)
    local req_headers = headers:build(path, "POST", token)

    local response, err = http_client:post(url, req_headers, "{}", 10)
    if not response then
        return nil, "网络请求失败: " .. tostring(err)
    end

    local data = http_client:parseJsonResponse(response)
    if data and data.code == 200 then
        return true
    end

    return nil, (data and data.message) or "打卡失败"
end

return PicacgAuth
