local ctx = assert(ctx, "source SDK context required")
-- source/picacg/headers.lua
-- 内置源 A 的请求头与签名
-- 签名逻辑集中在这里，其他模块不要各自拼请求头。

local logger = ctx.logger
local hmac = ctx.hmac
local config = ctx.config

local Headers = {}

-- API 常量
-- 只有 HTTPS: 源码里不再保留 http:// 基址, 从结构上禁止"失败就降级到明文"。
Headers.API_BASE_URL = "https://picaapi.picacomic.com/"
Headers.API_KEY  = "C69BAF41DA5ABD1FFEDC6D2FEA56B"
Headers.SECRET_KEY = "~d}$Q7$eIni=V)9\\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn"

-- 默认请求头值
Headers.DEFAULT_HEADERS = {
    ["accept"]            = "application/vnd.picacomic.com.v1+json",
    ["app-channel"]       = "2",
    ["app-version"]      = "2.2.1.2.3.3",
    ["app-uuid"]          = "defaultUuid",
    ["app-platform"]     = "android",
    ["app-build-version"] = "44",
    ["Content-Type"]      = "application/json; charset=UTF-8",
    ["User-Agent"]        = "okhttp/3.8.1",
    ["image-quality"]     = "original",
}

--- 生成签名
-- @param path: API 路径 (不含前导斜杠，如 "auth/sign-in")
-- @param ts: 字符串时间戳
-- @param method: HTTP 方法 (将被转为小写，如 "GET" → "get")
-- @param nonce: 随机 nonce 字符串
-- @return: hex 签名字符串
function Headers:generateSignature(path, ts, method, nonce)
    -- 确保 path 不含前导斜杠
    if path:sub(1, 1) == "/" then
        path = path:sub(2)
    end

    -- 构造签名字符串: path + timestamp + nonce + method + api_key
    local raw = path .. ts .. nonce .. string.lower(method) .. self.API_KEY
    raw = string.lower(raw)

    local signature = hmac.hmac_sha256_hex(self.SECRET_KEY, raw)
    if not signature then
        logger.err("Picayomi SourceAHeaders: HMAC签名生成失败")
        return nil
    end

    return signature
end

--- 构造完整请求头
-- @param path: API 路径 (不含前导斜杠)
-- @param method: HTTP 方法 ("GET"/"POST"/...)
-- @param token: 可选，用户 token
-- @return: headers 表
function Headers:build(path, method, token)
    -- 规范化 path
    if path:sub(1, 1) == "/" then
        path = path:sub(2)
    end

    local ts = tostring(os.time())
    local nonce = "b1ab87b4800d4d4590a11701b8551afa"
    local signature = self:generateSignature(path, ts, method, nonce)
    if not signature then
        return nil
    end

    -- 复制默认头
    local headers = {}
    for k, v in pairs(self.DEFAULT_HEADERS) do
        headers[k] = v
    end

    -- 添加签名相关头
    headers["api-key"]    = self.API_KEY
    headers["time"]       = ts
    headers["nonce"]      = nonce
    headers["signature"] = signature

    -- 图片质量
    --
    -- 只认 "original" / "low" 两个值。旧实现直接把设置项写进来 (low/medium/high),
    -- 而源 A 只认识 original/low —— "high" 落进服务端默认分支, 表现就是
    -- "选了高清反而更糊" (真机 2026-10-18)。
    --
    -- 注意这个头对**图床**其实无效 (实测同一 URL 带 original/high/low 返回的
    -- 字节完全相同); 真正决定清晰度的是 media.path 里那个 图片代理 地址 ——
    -- 见 source/picacg/api.lua 的 originalImageUrl。这里保留正确的取值, 免得
    -- 哪天服务端开始校验它时又踩一遍。
    headers["image-quality"] = (config:get("image_quality") == "low") and "low" or "original"

    -- Token
    if token and token ~= "" then
        headers["authorization"] = token
    end

    return headers
end

--- 构造完整 URL (始终 HTTPS)
-- 曾经允许传 use_https=false 走明文; 那实际上是降级逻辑的入口。现在固定 HTTPS。
-- @param path: API 路径 (如 "auth/sign-in" 或完整 URL)
-- @return: 完整 URL
function Headers:buildUrl(path)
    -- 完整 URL 直接返回 (但拒绝明文: 调用方不应把 http:// 传进来)
    if path:match("^https://") then
        return path
    end
    if path:match("^http://") then
        logger.warn("Picayomi SourceAHeaders: 拒绝明文 API 地址")
        return nil
    end

    -- 规范化 path
    if path:sub(1, 1) == "/" then
        path = path:sub(2)
    end

    local base = ctx.getSetting("base_url", self.API_BASE_URL):gsub("/+$", "")
    assert(base:match("^https://[%w%.%-]+$"), "API 地址必须为 HTTPS 域名")
    return base .. "/" .. path
end

return Headers
