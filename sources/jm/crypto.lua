local ctx = assert(ctx, "source SDK context required")
-- source/jm/crypto.lua
-- 内置源 B 接口响应体的解码
--
-- 响应中的 data 字段经过源侧编码，需要先解码再交给 JSON 解析。
-- 解码后的明文末尾可能带填充字节，按 JSON 的闭合符号截断。
-- 具体算法与密钥派生只在本文件与 headers 模块内使用，不要外传。

local logger = ctx.logger
local AES = ctx.aes
local B64 = ctx.b64
local Headers = require("headers")

local Crypto = {}

--- 去掉解密后尾部的填充垃圾
-- 明文尾部可能有随机字节, 截取到最后一次出现的 '}' 或 ']'
function Crypto.trimJson(text)
    if type(text) ~= "string" or text == "" then
        return nil, "解密结果为空"
    end
    local last_brace = text:match("^.*()}")
    local last_bracket = text:match("^.*()%]")
    local last_i = math.max(last_brace or 0, last_bracket or 0)
    if last_i == 0 then
        return nil, "解密结果不是 JSON"
    end
    return text:sub(1, last_i)
end

--- 解密 JW 的 data 字段
-- @param data_b64 接口返回的 data (base64 字符串)
-- @param secret   密钥材料 (接口用 "<ts>" 拼接 Headers.JM_SECRET, 域名配置用 Headers.DOMAIN_SECRET)
-- @return 明文 JSON 字符串 或 nil, err
function Crypto.decrypt(data_b64, secret)
    if type(data_b64) ~= "string" or data_b64 == "" then
        return nil, "空数据"
    end

    local cipher = B64.decode(data_b64)
    if not cipher or #cipher == 0 then
        return nil, "base64 解码失败"
    end
    if #cipher % 16 ~= 0 then
        return nil, "密文长度不是 16 的倍数"
    end

    -- 关键: key 是 md5 的十六进制字符串 (32 字节 ASCII) -> AES-256
    local key = Headers.md5hex(secret)
    if not key or #key ~= 32 then
        return nil, "md5 计算失败"
    end

    local plain = AES.decrypt_ecb(key, cipher)
    if not plain then
        return nil, "AES 解密失败"
    end

    local trimmed, err = Crypto.trimJson(plain)
    if not trimmed then
        logger.warn("Picayomi SourceB: " .. tostring(err))
        return nil, err
    end

    return trimmed
end

--- 解密并解析为 Lua 表
function Crypto.decodeJson(data_b64, secret)
    local text, err = Crypto.decrypt(data_b64, secret)
    if not text then return nil, err end

    local ok, parsed = pcall(function()
        return ctx.json.decode(text)
    end)
    if not ok or not parsed then
        return nil, "JSON 解析失败: " .. tostring(parsed)
    end
    return parsed
end

return Crypto
