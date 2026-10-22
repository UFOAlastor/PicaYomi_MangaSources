local ctx = assert(ctx, "source SDK context required")
-- source/jm/api.lua
-- 内置源 B 的 API 客户端
--
-- 通用返回结构为 { code, data }，data 需要经本源的 crypto 模块解码后再解析。
--
-- KOReader 侧需要注意:
--   1. 不依赖自动 gzip 解压 -> 请求头显式要求 identity
--   2. 图片走独立 CDN，不使用 API 域名
--   3. 域名可能变动 -> 从配置源拉取并逐个探测可用性

local json = ctx.json
local logger = ctx.logger
local _ = ctx.translate
local T = ctx.text.template
local HttpClient = ctx.http
local config = ctx.config
local SecretStore = ctx.secrets
local Redact = ctx.redact
local JN = ctx.values

local Headers = require("headers")
local Crypto = require("crypto")

local Api = {}

Api.current_domain = nil
Api.img_host = nil
Api.cookies = {}
Api.album_cache = {}
-- 专辑缓存的写入序号 (用于有界淘汰最久未写入的一条, 见 rememberAlbum)
local album_cache_seq = {}
Api.domains_checked = false
-- 上一次请求把候选域名全试遍了还是失败 -> 下一次必须先重新发现, 不能走快路径
-- (否则永远拿同一个死域名重试, 远端配置源里换过的新域名永远拿不到)
Api.domain_discovery_needed = false
-- 登录态必须显式记录: 普通请求也会下发会话 Cookie, 不能用"有 Cookie"判断已登录
Api.logged_in = false
Api.username = nil

local DEFAULT_TIMEOUT = 15

--- 墙钟 (秒, 带小数)
--- 用 os.clock 量网络会得到 0.0s —— 那是 CPU 时间, 不是等待时间
--- (老账: 0.9.5 之前整条链路的耗时都是这么量错的)。
local function now()
    local ok, socket = pcall(function() return {gettime=ctx.clock.now} end)
    if ok and type(socket) == "table" and socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

-- ============================================================================
-- HTTP 基础设施
-- ============================================================================

local Cookie = ctx.cookie

local function cookieHeader()
    return Cookie.toHeader(Api.cookies)
end

--- Cookie jar 的稳定指纹
-- pairs 的遍历顺序不稳定, 不能直接拿 toHeader() 的结果比"变没变"。
local function cookie_fingerprint()
    if type(Api.cookies) ~= "table" then return "" end
    local keys = {}
    for k in pairs(Api.cookies) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _i, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(Api.cookies[k])
    end
    return table.concat(parts, "; ")
end

local cookie_fp = ""
local last_cookie_save = 0
-- 服务端可能每个响应都轮换 Cookie。每次都加密 + 写 config.json 在 e-ink 存储上
-- 是明显的浪费; 60 秒内的中间变化先留在内存里, 到期后第一次响应再落盘。
local COOKIE_SAVE_INTERVAL = 60
Api._session_loaded = false

--- 从磁盘恢复会话 Cookie (加密存储, 见 util/secret_store.lua)
function Api.loadSavedCookies()
    local raw = SecretStore.get("jm_cookies")
    if type(raw) ~= "string" or raw == "" then return false end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then return false end
    Api.cookies = decoded
    cookie_fp = cookie_fingerprint()
    return true
end

--- 保存会话 Cookie; 没有变化时不写盘 (JM 可能每个响应都重发 Set-Cookie)
-- @param force true = 跳过节流 (登录成功时用)
function Api.saveCookies(force)
    local fp = cookie_fingerprint()
    if fp == cookie_fp then return true end
    if fp == "" then
        SecretStore.clear("jm_cookies")
        cookie_fp = ""
        return true
    end

    local now = os.time()
    if not force and last_cookie_save > 0
        and (now - last_cookie_save) < COOKIE_SAVE_INTERVAL then
        -- cookie_fp 不更新: 到期后的下一次调用会重新比较并落盘
        return true
    end

    local ok, encoded = pcall(json.encode, Api.cookies)
    if not ok or not encoded then return false end
    local saved = SecretStore.set("jm_cookies", encoded)
    if saved then
        cookie_fp = fp
        last_cookie_save = now
    end
    return saved
end

--- 懒加载磁盘上的会话 (源初始化 / 第一次判断登录态时)
function Api.ensureSessionLoaded()
    if Api._session_loaded then return end
    Api._session_loaded = true
    Api.loadSavedCookies()
end

--- 当前内存里的 Cookie 是否代表一个**登录过**的会话
-- 只看 Cookie 不够: 匿名浏览也会拿到 Cookie。jm_session 标记由登录成功写入,
-- 退出时清掉 —— 它本身不是敏感信息。
function Api.hasSavedSession()
    Api.ensureSessionLoaded()
    return config:get("jm_session") == true and next(Api.cookies) ~= nil
end

--- 收集响应里的 Set-Cookie
-- 漏掉会话 cookie 会导致所有需要登录的接口(收藏等)被当成匿名请求
-- → 401 或"成功但空列表"。
local function absorbCookies(resp)
    if not resp or not resp.headers then return end
    local n = Cookie.absorb(Api.cookies, resp.headers)
    if n > 0 then
        if logger.enabled then logger.dbg("Picayomi SourceB: 吸收 " .. n .. " 个 cookie") end
        -- 只持久化**登录后**的 Cookie: 匿名浏览的 Cookie 不该让下次启动
        -- 误判为已登录 (登录本身在 Api.login 里显式保存)。
        if Api.logged_in then
            pcall(Api.saveCookies)
        end
    end
end

--- 原始请求 (返回解析后的响应体字符串)
local function rawRequest(method, url, headers, body, timeout)
    local resp, err = HttpClient:request(method, url, headers, body, timeout or DEFAULT_TIMEOUT)
    if not resp then
        return nil, err
    end
    absorbCookies(resp)
    return resp
end

-- ============================================================================
-- 域名发现与选择
-- ============================================================================

--- 从配置源拉取并解密域名列表
function Api.fetchDomainsFromConfig()
    for _idx, url in ipairs(Headers.DOMAIN_CONFIG_URLS) do
        local resp = rawRequest("GET", url, {
            ["user-agent"] = Headers.UA,
            ["Accept-Encoding"] = "identity",
            ["Accept"] = "*/*",
        }, nil, 10)

        if resp and resp.body and #resp.body > 0 and (resp.status_code or 0) == 200 then
            local text = Crypto.decrypt(resp.body, Headers.DOMAIN_SECRET)
            if text then
                local ok, parsed = pcall(json.decode, text)
                if ok and parsed and type(parsed.Server) == "table" then
                    local list = {}
                    for _i, d in ipairs(parsed.Server) do
                        local nd = Headers.normalizeDomain(d)
                        if nd then table.insert(list, nd) end
                    end
                    if #list > 0 then
                        if logger.enabled then logger.info("Picayomi SourceB: 从配置源获取到 " .. #list .. " 个域名") end
                        return list
                    end
                end
            end
        end
    end
    return {}
end

--- 候选域名 (配置缓存 -> 远端配置 -> 内置兜底)
function Api.candidateDomains()
    local override = ctx.getSetting("base_url", "")
    if override ~= "" then
        assert(override:match("^https://[%w%.%-]+/?$"), "API 地址必须为 HTTPS 域名")
        return { Headers.normalizeDomain(override) }
    end
    local cached = config:get("jm_domains")
    if type(cached) == "table" and #cached > 0 then
        return cached
    end
    return Headers.FALLBACK_DOMAINS
end

--- 探测某个域名是否可用
local function probeDomain(domain)
    local ts = Headers.timestamp()
    local resp = rawRequest("GET", "https://" .. domain .. "/latest?page=1",
        Headers.apiHeaders(ts), nil, 10)
    if not resp or (resp.status_code or 0) ~= 200 or not resp.body then
        return false
    end
    local ok, parsed = pcall(json.decode, resp.body)
    return ok and parsed and parsed.code == 200
end

--- 选择可用域名 (结果写入配置, 下次直接复用)
function Api.ensureDomain(force)
    if ctx.getSetting("base_url", "") ~= "" then
        Api.current_domain = Api.candidateDomains()[1]
        return Api.current_domain
    end
    if Api.current_domain and not force then
        return Api.current_domain
    end

    -- 快路径: 直接复用上次成功的域名, **不探测、也不联网拉配置源**。
    --
    -- 真机 2026-10-18 的账: 一次 收藏接口 花了 7.2s, 而同一个请求在 Mac 上
    -- 只要 1.2s。差额的大头不在 HTTP, 在"第一次请求之前先把域名发现跑一遍":
    -- 拉配置源 (最多 2 个 URL × 10s 超时) + 逐个 probeDomain (每个 probe 又是
    -- 一次完整请求)。可配置里明明记着上次成功的域名 —— rememberDomain 每次
    -- 请求成功都会写回, 这个发现流程在绝大多数情况下纯属白跑。
    --
    -- 域名真失效也不要紧: request() 会按候选表换下一个; 全都失败时它会把
    -- current_domain 清掉, 下一次请求才会走下面这套完整发现 —— 那才是它
    -- 该出现的场合 (缓存和内置兜底都不可用)。
    if not force and not Api.domain_discovery_needed then
        local cached = Api.candidateDomains()
        local first = type(cached) == "table" and cached[1]
        if first then
            Api.current_domain = first
            Api.domains_checked = true
            if logger.enabled then logger.info("Picayomi SourceB: 直接复用上次的域名 " .. first .. " (跳过探测)") end
            return first
        end
    end

    -- 走到这里 = 缓存与内置兜底全不可用, 或者上一轮已经全试遍: 该真正发现了
    Api.domain_discovery_needed = false

    local candidates = {}
    local seen = {}
    local function add(list)
        for _idx, d in ipairs(list or {}) do
            local nd = Headers.normalizeDomain(d)
            if nd and not seen[nd] then
                seen[nd] = true
                table.insert(candidates, nd)
            end
        end
    end

    add(Api.candidateDomains())
    add(Api.fetchDomainsFromConfig())
    add(Headers.FALLBACK_DOMAINS)

    for _idx, d in ipairs(candidates) do
        if probeDomain(d) then
            Api.current_domain = d
            Api.domains_checked = true
            if logger.enabled then logger.info("Picayomi SourceB: 使用域名 " .. d) end
            return d
        end
    end

    -- 探测失败也要落标记: 否则每个请求都会重新拉配置源 + 逐个探测 (每次几十秒),
    -- 反而把"暂时连不上"放大成"卡死"。下次 Api.ensureDomain(true) 才会重试。
    Api.domains_checked = true
    logger.err("Picayomi SourceB: 没有可用域名")
    return nil
end

--- 记住可用域名 (供源在成功请求后写回配置)
local function rememberDomain(domain)
    local list = { domain }
    local seen = { [domain] = true }
    for _idx, d in ipairs(config:get("jm_domains") or {}) do
        if not seen[d] then
            seen[d] = true
            table.insert(list, d)
        end
    end
    config:set("jm_domains", list)
end

-- ============================================================================
-- 接口调用
-- ============================================================================

--- 一次失败的请求值不值得换个域名再试
--
-- 520/521/522/524 是 Cloudflare 家族的"回源失败" (源站超时 / 连不上 / 挂了),
-- 429 是限流; 连响应都拿不到 (连接被重置 / 超时 / TLS 失败) 同理。
-- 401/403/404 **不在其中**: 那是登录态或路径的问题, 换域名只会把会话丢掉,
-- 越试越糟 (401 有单独的"用磁盘凭据重登"链路)。
local function is_transient(status)
    if not status then return true end
    return status == 429 or (status >= 500 and status <= 599)
end

--- 本次请求的域名尝试顺序: 当前域名 -> 候选表 -> 内置兜底 (去重)
local function domainPlan()
    if ctx.getSetting("base_url", "") ~= "" then return Api.candidateDomains() end
    local plan, seen = {}, {}
    local function add(list)
        for _idx, d in ipairs(list or {}) do
            local nd = Headers.normalizeDomain(d)
            if nd and not seen[nd] then
                seen[nd] = true
                plan[#plan + 1] = nd
            end
        end
    end
    add({ Api.current_domain })
    add(Api.candidateDomains())
    add(Headers.FALLBACK_DOMAINS)
    return plan
end

--- 一次请求最多试几个域名
--
-- 只换一台就够: 失败的那次已经耗掉一整个超时 (真机 522 那次等了 20 秒),
-- 再按候选表一路试下去, 用户得盯着"加载中"干等一分钟 —— 比直接报错更糟。
local MAX_DOMAIN_ATTEMPTS = 2

--- 发请求 + 解析 (GET / POST 共用)
--
-- 为什么"换域名重试"放在这一层: 响应体的 AES 密钥用到**本次请求的 ts**
-- (tostring(ts) .. JM_SECRET), 所以每次重试都必须重算 ts 与请求头 ——
-- 不能在外层拿着解析好的结果重发。
--
-- @return data, err, transient
local function request(method, path, body, timeout, extra_headers, max_attempts)
    local t_all = logger.enabled and now() or 0
    -- 第一次用 (还没有当前域名, 也还没探过): 先走一次域名发现。
    -- 单独计时 —— 真机上"这一次请求 7 秒"到底是网络慢还是发现流程慢,
    -- 只有把它和 HTTP 分开才看得出来。
    local discovery_dt = 0
    if not Api.current_domain and not Api.domains_checked then
        local t_disc = logger.enabled and now() or 0
        Api.ensureDomain()
        discovery_dt = logger.enabled and (now() - t_disc) or 0
    end

    local plan = domainPlan()
    if #plan == 0 then return nil, "没有可用域名", false end

    local last_err, transient = "没有可用域名", false
    -- 这一次失败是"域名不行"还是"接口不行"? 只有前者才该要求下一次重新发现。
    -- 401/业务错误说明域名是好的, 换域名毫无意义 —— 而且会把 /login 的重试
    -- 变成一次完整的域名发现 (回归测试 17.1/17.2 当场抓到)。
    local domain_bad = false
    local limit = math.min(#plan, max_attempts or MAX_DOMAIN_ATTEMPTS)
    for attempt = 1, limit do
        local domain = plan[attempt]
        local ts = Headers.timestamp()
        local headers = Headers.apiHeaders(ts)
        for k, v in pairs(extra_headers or {}) do headers[k] = v end
        local cookie = cookieHeader()
        if cookie then headers["Cookie"] = cookie end

        local t_http = logger.enabled and now() or 0
        local resp, err = rawRequest(method, "https://" .. domain .. path, headers, body, timeout)
        local http_dt = logger.enabled and (now() - t_http) or 0
        local status = resp and (resp.status_code or 0)

        if not resp then
            last_err, transient, domain_bad = err or "网络错误", true, true
        elseif status ~= 200 then
            last_err, transient = "HTTP " .. tostring(status), is_transient(status)
            -- 域名可能已失效, 清掉以便下次重新选择
            if status == 403 or status == 404 then
                Api.current_domain = nil
                domain_bad = true
            end
        else
            local ok, parsed = pcall(json.decode, resp.body)
            if not ok or type(parsed) ~= "table" then
                return nil, "响应不是 JSON", false
            end
            if parsed.code ~= 200 then
                return nil, parsed.errorMsg or parsed.msg or ("code=" .. tostring(parsed.code)), false
            end
            local data
            if type(parsed.data) == "table" then
                -- 有些接口 (如 设置接口) 的 data 未加密
                data = parsed.data
            elseif type(parsed.data) == "string" then
                data = Crypto.decodeJson(parsed.data, tostring(ts) .. Headers.JM_SECRET)
                if data == nil then return nil, "响应解密失败", false end
            else
                return nil, "缺少 data 字段", false
            end
            Api.current_domain = domain
            rememberDomain(domain)

            -- 慢请求记一笔。三个数摆在一起才分得清"源 B 慢"是慢在网络、慢在换域名、
            -- 还是慢在请求之前的域名发现。Diag 是跨层工具, 这里按需加载:
            -- 加载不到就什么都不做, 源层不该因为诊断而跑不起来。
            local total = logger.enabled and (now() - t_all) or 0
            if logger.enabled and (total >= 1.5 or attempt > 1 or discovery_dt >= 0.05) then
                local ok_d, Diag = pcall(function() return ctx.trace end)
                if ok_d and Diag and Diag.enabled then
                    pcall(Diag.mark, string.format(
                        "jm %s %s %.1fs (域名 %s, 第 %d 次, HTTP %.1fs%s)",
                        method, Redact.url(path), total, tostring(domain), attempt, http_dt,
                        discovery_dt >= 0.05
                            and string.format(", 含域名发现 %.1fs", discovery_dt) or ""))
                end
            end
            return data, nil, false
        end

        if logger.enabled then logger.info(string.format("Picayomi SourceB: %s %s%s 失败: %s%s",
            method, domain, Redact.url(path), Redact.text(last_err),
            transient and (attempt < limit and " (换域名重试)" or " (已换过域名)") or "")) end
        if not transient then break end
    end

    -- 全试过都不行: 清掉 current_domain 并要求下一次**重新发现**。
    -- 这一条不能省: 快路径会一直复用缓存里的第一个域名, 如果它已经死了,
    -- 不要求重新发现就永远拿同一个死域名重试, 远端配置源里换过的新域名永远拿不到。
    if domain_bad or transient then
        Api.current_domain = nil
        Api.domains_checked = false
        Api.domain_discovery_needed = true
    end
    return nil, Redact.text(last_err), transient
end

--- GET 接口, 返回解密后的数据
-- Cookie 过期时 (401) 会用已保存的凭据自动重登并重试一次;
-- 5xx / 连不上时自动换一个域名重试一次 (见 request)
function Api.get(path, timeout)
    local data, err = request("GET", path, nil, timeout)

    -- 401 一律尝试用磁盘凭据恢复会话:
    -- 进程刚启动时 logged_in 必为 false, 但凭据可能是有效的。
    if not data and err and tostring(err):find("401", 1, true) and Api.hasSavedCredentials() then
        if logger.enabled then logger.info("Picayomi SourceB: 收到 401, 尝试用已保存凭据重新登录") end
        if Api.reLogin() then
            return Api._get(path, timeout)
        end
    end
    return data, err
end

function Api._get(path, timeout)
    return request("GET", path, nil, timeout)
end

--- POST 接口 (表单), 返回解密后的数据
--
-- 与 Api.get 一样带 401 恢复: 本进程里第一次需要登录态的**往往就是它**
-- (收藏是唯一要登录的写操作)。真机 2026-10-18 的现场:
--   00:33 源 B 初始化后只发过公开列表请求 (不带 Cookie 也 200), 所以 cookie 罐是空的;
--   00:39:43 用户点收藏 -> POST 收藏接口 -> 401 -> 界面上只有一句 "HTTP 401"。
-- 根因不是端点或请求头, 而是**这条路径没有重登重试** —— Api.get 有, Api.post 没有。
--
-- @param no_retry 只发一次, 不换域名重试 (给 收藏接口 这种**非幂等**的切换接口用;
--        自动重发在"第一次其实成功了、只是响应丢了"的情况下会把状态切回去)
function Api.post(path, body, timeout, no_retry)
    local data, err, transient = request("POST", path, body, timeout,
        { ["Content-Type"] = "application/x-www-form-urlencoded" },
        no_retry and 1 or nil)
    if data then return data end

    -- /login 自己不能走这条恢复链 (reLogin -> login -> post 会递归)
    if path == "/login" then return nil, err end

    if err and tostring(err):find("401", 1, true) then
        if Api.hasSavedCredentials() then
            if logger.enabled then logger.info("Picayomi SourceB: 写操作收到 401, 尝试用已保存凭据重新登录") end
            if Api.reLogin() then
                return Api._post(path, body, timeout, no_retry)
            end
        end
        -- 没凭据 / 重登失败: 别把裸的 "HTTP 401" 甩给用户, 他不知道该干什么
        return nil, _("登录已过期，请重新登录")
    end

    if transient then
        -- "HTTP 520" 对用户没有意义: 说清"暂时不可用, 稍后再试"才有用
        return nil, T(_("服务器暂时不可用 (%1)，请稍后重试"), tostring(err))
    end
    return nil, err
end

function Api._post(path, body, timeout, no_retry)
    return request("POST", path, body, timeout,
        { ["Content-Type"] = "application/x-www-form-urlencoded" },
        no_retry and 1 or nil)
end

-- ============================================================================
-- 图片 CDN
-- ============================================================================

--- 获取图片 CDN 地址 (由 设置接口 返回, 带缓存与兜底)
function Api.ensureImgHost(force)
    if Api.img_host and not force then
        return Api.img_host
    end
    local cached = config:get("jm_img_host")
    if cached and not force then
        Api.img_host = Headers.normalizeHost(cached)
        if Api.img_host then return Api.img_host end
    end

    local data = Api.get("/setting?app_img_shunt=1")
    if data and data.img_host then
        Api.img_host = Headers.normalizeHost(data.img_host)
        if Api.img_host then
            config:set("jm_img_host", Api.img_host)
            if logger.enabled then logger.info("Picayomi SourceB: 图片 CDN = " .. Api.img_host) end
            return Api.img_host
        end
    end

    Api.img_host = Headers.FALLBACK_IMG_HOST
    return Api.img_host
end

--- 封面 URL
function Api.coverUrl(comic_id)
    local host = Api.ensureImgHost()
    if not host then return nil end
    return host .. "/media/albums/" .. tostring(comic_id) .. "_3x4.jpg"
end

--- 正文图片 URL
function Api.pageUrl(chapter_id, filename)
    local host = Api.ensureImgHost()
    if not host then return nil end
    return host .. "/media/photos/" .. tostring(chapter_id) .. "/" .. tostring(filename)
end

-- ============================================================================
-- 数据标准化
-- ============================================================================

local function joinCategories(comic)
    local out = {}
    local seen = {}
    -- 注意: category.title 可能是 JSON null (userdata), 必须用 JN.str 过滤
    -- 另外 category 与 category_sub 常常同名 (如 同人/同人), 这里去重
    local function add(t)
        if t and t ~= "" and not seen[t] then
            seen[t] = true
            table.insert(out, t)
        end
    end
    if type(comic.category) == "table" then
        add(JN.str(comic.category.title))
    end
    if type(comic.category_sub) == "table" then
        add(JN.str(comic.category_sub.title))
    end
    return out
end

--- 秒级时间戳 -> "YYYY-MM-DD"
-- 源 B 的 update_at / addtime 都是 epoch 秒 (不是字符串日期), 而卡片与详情页
-- 都按 "YYYY-MM-DD" 展示 —— 在源这一层就统一掉, 免得每个调用方各转一次。
local function date_text(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return nil end
    local ok, s = pcall(os.date, "%Y-%m-%d", ts)
    return (ok and s) or nil
end

--- 把 源 B 的列表项标准化为项目内部漫画结构
function Api.normalizeBrief(comic)
    if type(comic) ~= "table" then return nil end
    local id = JN.str(comic.id) or JN.num(comic.id)
    if not id then return nil end
    id = tostring(id)
    return {
        _id = id,
        title = JN.str(comic.name) or ("JM" .. id),
        author = JN.str(comic.author) or "",
        categories = joinCategories(comic),
        -- 源 B 列表项没有页数/话数, 用作品编号作为第三行信息 (与 PicaComic 一致)。
        -- **放在 subtitle 而不是 description**: description 是简介, 详情页会原样
        -- 显示在简介区 —— 以前那里显示的是"JM1483331" (作品编号), 而不是简介。
        subtitle = "JM" .. id,
        thumb = Api.coverUrl(id),
        -- 列表接口只给 update_at (epoch 秒)。卡片/详情按日期展示, 这里转好。
        update_time = date_text(comic.update_at),
        isFavourite = JN.bool(comic.is_favorite),
    }
end

local function normalizeBriefList(list)
    local out = {}
    for _idx, c in ipairs(list or {}) do
        local n = Api.normalizeBrief(c)
        if n then table.insert(out, n) end
    end
    return out
end

-- ============================================================================
-- 内存缓存 (对齐 picacg 的 TTL 策略)
-- 没有缓存时每次进列表/翻页/返回都要走一次网络, 在 Kindle 上体感很差。
-- ============================================================================
local CACHE_TTL = {
    CATEGORIES = 86400,   -- 1 天
    COMICS     = 3600,    -- 1 小时
    DETAIL     = 86400,   -- 1 天
    IMAGES     = 3600,    -- 1 小时
    SEARCH     = 1800,    -- 30 分钟
    -- 收藏: 5 分钟。收藏是**个人列表**, 用户可能刚在网页/别的设备上加过,
    -- 所以不能像最新列表那样缓存一小时; 但同一次会话里来回进出收藏页
    -- (真机上每次都要同步等 1~4 秒) 完全没必要重取。
    -- 自己加/取消收藏走 Api.clearListCache (清 "jm:" 前缀), 立刻失效。
    FAVORITES  = 300,
}

local function cacheGet(key)
    local ok, cache = pcall(function() return ctx.cache end)
    if not ok or not cache then return nil end
    local ok2, v = pcall(function() return cache:getData(key) end)
    if not ok2 then return nil end
    return v
end

local function cacheSet(key, value, ttl)
    local ok, cache = pcall(function() return ctx.cache end)
    if not ok or not cache then return end
    pcall(function() cache:cacheData(key, value, os.time() + ttl) end)
end

--- 带缓存的取数: 命中直接返回, 未命中执行 fn 并写入缓存
local function cached(key, ttl, fn)
    local hit = cacheGet(key)
    if hit then return hit end
    local value, err = fn()
    if not value then return nil, err end
    cacheSet(key, value, ttl)
    return value
end

--- 清空 源 B 的列表类缓存 (收藏/取消收藏后调用, 避免看到旧状态)
function Api.clearListCache()
    local ok, cache = pcall(function() return ctx.cache end)
    if not ok or not cache then return end
    pcall(function() cache:clearPattern("jm:") end)
    Api.album_cache = {}
    album_cache_seq = {}
end

--- 专辑详情缓存有界化
--
-- 每条 detail 都带完整章节数组 (长篇可上百项)。无上限时, 一次会话里看过的每本
-- 都会一直留着 —— 在只有 ~130MB 可用内存的设备上就是白白累积。
-- 超限时淘汰**最久未写入**的那一条 (table 没有插入序, 因此单独记一个序号)。
local ALBUM_CACHE_MAX = 24
local album_cache_counter = 0

local function rememberAlbum(id, detail)
    album_cache_counter = album_cache_counter + 1
    Api.album_cache[id] = detail
    album_cache_seq[id] = album_cache_counter

    local count = 0
    for _ in pairs(Api.album_cache) do count = count + 1 end
    if count > ALBUM_CACHE_MAX then
        local oldest_id, oldest_seq
        for k, seq in pairs(album_cache_seq) do
            if not oldest_seq or seq < oldest_seq then
                oldest_id, oldest_seq = k, seq
            end
        end
        if oldest_id then
            Api.album_cache[oldest_id] = nil
            album_cache_seq[oldest_id] = nil
        end
    end
end

-- ============================================================================
-- 业务接口
-- ============================================================================

--- 最新 / 推荐列表 (可排序)
--
-- @param order 排序取值与分类页一致: mr 最新 / mv 最多观看 / mp 最多图片 / tf 最多喜欢
--
-- 端点选择 (实测 2026-10-18):
--   * 最新列表接口 **不接受任何排序参数** —— 加 order= / o= / sort= 返回的都是同一份数据
--     (80 条, 首项完全相同)。所以只拿它当"最新"。
--   * 其余排序走 分类筛选接口: 那是站点"全部"列表的筛选接口, c 留空即全库,
--     o 是排序。实测 o=mv 首项是观看最多的作品、o=mr 是按时间倒序、o=tf 是喜欢最多。
--   这也是"推荐/最新为什么没有排序按钮"的答案: 以前只接了 最新列表接口, 而它没有这个能力。
function Api.getLatest(page, order)
    page = page or 1
    order = tostring(order or "mr")
    return cached("jm:latest:" .. order .. ":" .. page, CACHE_TTL.COMICS, function()
        local path
        if order == "mr" then
            path = "/latest?page=" .. tostring(page)
        else
            path = "/categories/filter?o=" .. order .. "&c=&page=" .. tostring(page)
        end
        local data, err = Api.get(path)
        if not data then return nil, err end
        if type(data) ~= "table" then return nil, "列表数据格式异常" end
        -- 两个端点的列表位置不同: 最新列表接口 直接是数组, filter 放在 content 里
        local list = type(data.content) == "table" and data.content or data
        return {
            comics = normalizeBriefList(list),
            page = page,
            -- 源 B 的 latest 不给总页数 —— 这里**必须留 nil**, 不能塞一个"足够大的"
            -- 哨兵值 (以前是 9999)。列表页对 total_pages 的语义是"可信的页数":
            -- 有了它页脚就会显示"第 1/9999 页"并允许跳到第 9999 页, 那是假的。
            -- 留 nil 时列表按 has_more=true 处理 (见 visual_comic_list 的构造),
            -- 照样能一直往下翻, 页脚只显示"第 N 页 · 已加载 K 项"。
            pages = nil,
        }
    end)
end

--- percent-encode (RFC 3986) —— 源 B 的 /search 收到**原始 UTF-8 字节**会直接 400
--- (实测 2026-10-18: search_query=韓漫 -> 400, %E9%9F%93%E6%BC%AB -> 200)。
--- 英文关键词碰巧能过, 所以这个坑只在中文/日文搜索时暴露。
local function urlencode(str)
    return (tostring(str):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Api.getSearch(keyword, page, order)
    page = page or 1
    order = tostring(order or "mr")
    -- 缓存键用**原关键词** (与显示一致), 只有拼 URL 时才编码。
    local keyword_key = tostring(keyword or "")
    return cached("jm:search:" .. order .. ":" .. page .. ":" .. keyword_key,
        CACHE_TTL.SEARCH, function()
            -- 空格编码成 %20 而不是 '+' —— '+' 在 query 里虽然也表示空格, 但
            -- 关键词里真的含 '+' 时就分不清了。
            local kw = urlencode(keyword_key)
            local path = "/search?&search_query=" .. kw ..
                "&o=" .. order .. "&page=" .. tostring(page)
            local data, err = Api.get(path)
            if not data then return nil, err end
            local comics = normalizeBriefList(data.content)
            local total = JN.num(data.total, #comics)
            local per = math.max(#comics, 1)
            return {
                comics = comics,
                page = page,
                total = total,
                pages = math.max(1, math.ceil(total / per)),
            }
        end)
end

local function parseCategories(data)
    local out = {}
    for _idx, c in ipairs(JN.list(data.categories)) do
        if type(c) == "table" then
            local slug = JN.str(c.slug)
            local name = JN.str(c.name)
            if slug and name then
                local subs = {}
                for _i, sc in ipairs(JN.list(c.sub_categories)) do
                    if type(sc) == "table" then
                        local sslug = JN.str(sc.slug) or JN.str(sc.CID)
                        local sname = JN.str(sc.name)
                        if sslug and sname then
                            table.insert(subs, {
                                _id = sslug,
                                title = sname,
                                category = sslug,
                            })
                        end
                    end
                end
                table.insert(out, {
                    _id = slug,
                    title = name,
                    categories = subs,
                    category = slug,
                })
            end
        end
    end
    -- blocks 是源站提供的主题/角色等标签分类, 通过关键词搜索进入。
    -- 主分类走 filter, 标签分类走 search, 不把标签当作分类 slug 发送。
    for _, block in ipairs(JN.list(data.blocks)) do
        if type(block) == "table" then
            local group = JN.str(block.title, "")
            for _, keyword in ipairs(JN.str_list(block.content)) do
                if keyword ~= "" then
                    out[#out + 1] = {
                        _id = "jm-tag:" .. keyword,
                        title = group ~= "" and (group .. " / " .. keyword) or keyword,
                    }
                end
            end
        end
    end
    return out
end

local CATEGORY_CACHE_KEY = "jm:categories:v2"
local CATEGORY_SNAPSHOT_KEY = "jm_categories_cache"

local function savedCategories(snapshot)
    if type(snapshot) ~= "table" or snapshot.version ~= 2
            or type(snapshot.categories) ~= "table" or #snapshot.categories == 0 then
        return nil
    end
    for _idx, category in ipairs(snapshot.categories) do
        if type(category) ~= "table" or type(category._id) ~= "string"
                or type(category.title) ~= "string" or category.title == "" then
            return nil
        end
    end
    return snapshot.categories
end

function Api.getCategories()
    local hit = cacheGet(CATEGORY_CACHE_KEY)
    if hit then return hit end

    -- 分类变化很少, 重启后优先复用磁盘快照, 不必再承担一次域名发现/网络请求。
    local snapshot = config:get(CATEGORY_SNAPSHOT_KEY)
    local saved = savedCategories(snapshot)
    local remaining = saved and ((tonumber(snapshot.expires_at) or 0) - os.time()) or 0
    if remaining > 0 then
        cacheSet(CATEGORY_CACHE_KEY, saved, remaining)
        return saved
    end

    local ok, data, err = pcall(Api.get, "/categories")
    if not ok then err, data = data, nil end
    local categories = type(data) == "table" and parseCategories(data) or {}
    if #categories > 0 then
        -- 写盘失败不影响本次成功的数据; 下次仍可重取或使用内置快照。
        pcall(config.set, config, CATEGORY_SNAPSHOT_KEY, {
            version = 2, categories = categories, expires_at = os.time() + CACHE_TTL.CATEGORIES,
        })
        cacheSet(CATEGORY_CACHE_KEY, categories, CACHE_TTL.CATEGORIES)
        return categories
    end

    -- 短期网络失败不能让整个分类入口不可用, 也不能用空响应覆盖最后一次成功数据。
    local fallback = saved or parseCategories(require("category_defaults"))
    if logger.enabled then logger.info("Picayomi SourceB: 分类接口暂不可用, 使用" .. (saved and "历史" or "内置")
        .. "分类: " .. Redact.text(err or "分类数据为空或格式异常")) end
    cacheSet(CATEGORY_CACHE_KEY, fallback, 300)
    return fallback
end

function Api.getCategoryComics(category, page, order)
    local keyword = type(category) == "string" and category:match("^jm%-tag:(.+)$")
    if keyword then return Api.getSearch(keyword, page, order) end
    page = page or 1
    order = tostring(order or "mr")
    local cat = tostring(category or "")
    return cached("jm:cat:" .. order .. ":" .. cat .. ":" .. tostring(page),
        CACHE_TTL.COMICS, function()
            local path = "/categories/filter?o=" .. order ..
                "&c=" .. urlencode(cat) .. "&page=" .. tostring(page)
            local data, err = Api.get(path)
            if not data then return nil, err end
            local comics = normalizeBriefList(data.content)
            local total = JN.num(data.total, #comics)
            local per = math.max(#comics, 1)
            return {
                comics = comics,
                page = page,
                total = total,
                pages = math.max(1, math.ceil(total / per)),
            }
        end)
end

-- JM 的评论正文是 HTML, 回复随父评论一起返回, 每页固定 10 条父评论。
local function normalizeComment(raw, include_replies)
    if type(raw) ~= "table" then return nil end
    local id = JN.str(raw.CID) or JN.num(raw.CID)
    if not id then return nil end
    local replies = {}
    if include_replies then
        for _, reply in ipairs(JN.list(raw.replys)) do
            local normalized = normalizeComment(reply, false)
            if normalized then replies[#replies + 1] = normalized end
        end
    end
    return {
        _id = tostring(id),
        author = { name = JN.str(raw.nickname) or JN.str(raw.username) or JN.str(raw.name) or "" },
        content = ctx.text.htmlToPlainText(JN.str(raw.content, "")),
        created_at = JN.str(raw.addtime) or JN.num(raw.addtime),
        likesCount = JN.num(raw.likes, 0),
        replies = replies,
        commentsCount = #replies,
    }
end

function Api.getComments(comic_id, page)
    local id = tostring(comic_id)
    page = math.max(1, math.floor(tonumber(page) or 1))
    return cached("jm:comments:" .. id .. ":" .. page, 600, function()
        local data, err = Api.get("/forum?mode=manhua&aid=" .. urlencode(id) .. "&page=" .. page)
        if not data then return nil, err end
        if type(data) ~= "table" or type(data.list) ~= "table" then
            return nil, _("评论数据格式异常")
        end
        local comments = {}
        for _, raw in ipairs(data.list) do
            local comment = normalizeComment(raw, true)
            if comment then comments[#comments + 1] = comment end
        end
        local total = JN.num(data.total, #comments)
        return {
            comments = comments,
            total = total,
            page = page,
            pages = math.max(1, math.ceil(total / 10)),
        }
    end)
end

--- 作品详情 (含章节列表)
function Api.getAlbum(comic_id)
    local id = tostring(comic_id)
    return cached("jm:album:" .. id, CACHE_TTL.DETAIL, function()
        return Api._fetchAlbum(id)
    end)
end

function Api._fetchAlbum(id)
    local data, err = Api.get("/album?id=" .. id)
    if not data then return nil, err end

    local detail = {
        _id = id,
        title = JN.str(data.name) or ("JM" .. id),
        author = JN.str(data.author) or "",
        description = JN.str(data.description, ""),
        tags = JN.str_list(data.tags),
        likesCount = JN.num(data.likes, 0),
        viewsCount = JN.num(data.total_views, 0),
        epsCount = 0,   -- 章节构建完后按**实际**章节数回填 (见下)
        pagesCount = JN.num(data.total_photos, 0),
        thumb = Api.coverUrl(id),
        isFavourite = JN.bool(data.is_favorite),
        -- addtime 可能是 JSON null (userdata) / 字符串数字: 用 date_text 同一套规则清洗,
        -- 不能原样透传 (消费方拿它做比较 / 拼接会炸)。
        updated_at = tonumber(data.addtime),
        -- 详情页的"更新时间"读的是 update_time (与列表同一套字段);
        -- 只写 updated_at 的话那一行永远不显示 (真机反馈: 详情页没有更新时间)。
        update_time = date_text(data.addtime),
        chapters = {},
    }

    local series = JN.list(data.series)
    if #series == 0 then
        -- 单话作品: 章节号就是作品号
        table.insert(detail.chapters, {
            _id = id,
            title = detail.title,
            order = 1,
            sort = 1,
        })
    else
        for idx, s in ipairs(series) do
            if type(s) == "table" then
                local sid = JN.str(s.id) or JN.num(s.id)
                if sid then
                    local name = JN.str(s.name, "")
                    local sort = JN.num(s.sort, idx)
                    table.insert(detail.chapters, {
                        _id = tostring(sid),
                        title = name ~= "" and name or ("第" .. tostring(sort) .. "话"),
                        order = idx,
                        sort = sort,
                    })
                end
            end
        end
    end

    -- 章节数以**实际建出来的章节**为准: series 里可能混着缺 id 的脏项 / 非表项,
    -- 构建时已被跳过。按原始长度算会让"共 N 话"比列表里能点的章节多
    -- (页脚汇总行与章节列表对不上)。单话作品 (series 为空) 上面补了 1 章, 这里也是 1。
    detail.epsCount = #detail.chapters

    rememberAlbum(id, detail)
    return detail
end

--- 取章节列表 (供 source:getChapters 使用)
function Api.getChapters(comic_id)
    local detail, err = Api.getAlbum(comic_id)
    if not detail then return nil, err end
    return {
        episodes = detail.chapters,
        page = 1,
        pages = 1,
        total = #detail.chapters,
    }
end

--- 解析章节 id: 优先用缓存, 否则回源
function Api.resolveChapterId(comic_id, chapter_order)
    local id = tostring(comic_id)
    local detail = Api.album_cache[id]
    local err
    if not detail then
        detail, err = Api.getAlbum(id)
    end
    -- 取详情失败 (网络 / 5xx) 要把**真实原因**带出去: 调用方拿到 nil 却不知道为什么,
    -- 只能报"找不到该章节", 用户会以为作品被删了, 实际只是网络抖了一下。
    if not detail then return nil, err or "获取作品详情失败" end

    local order = tonumber(chapter_order)
    if not order then return nil, "找不到该章节" end
    for _idx, ch in ipairs(detail.chapters) do
        if ch.order == order then return ch._id end
    end
    return nil, "找不到该章节"
end

--- 取某一话的图片列表
function Api.getChapterImages(comic_id, chapter_order)
    local chapter_id, resolve_err = Api.resolveChapterId(comic_id, chapter_order)
    if not chapter_id then return nil, resolve_err or "找不到该章节" end

    return cached("jm:chapter:" .. tostring(chapter_id), CACHE_TTL.IMAGES, function()
        local data, err = Api.get("/chapter?id=" .. tostring(chapter_id))
        if not data then return nil, err end

        local images = {}
        for _idx, name in ipairs(JN.str_list(data.images)) do
            local url = Api.pageUrl(chapter_id, name)
            if url then table.insert(images, { url = url }) end
        end
        return { images = images, chapter_id = chapter_id }
    end)
end

-- ============================================================================
-- 账号与收藏
-- ============================================================================

function Api.login(username, password)
    username = tostring(username or "")
    password = tostring(password or "")
    if username == "" or password == "" then
        return nil, "用户名和密码不能为空"
    end

    local body = "username=" .. username .. "&password=" .. password
    -- 必须走 _post: Api.post 的 401 恢复会调用 reLogin, 而 reLogin 又调 login
    local data, err = Api._post("/login", body, 20)
    if not data then
        Api.logged_in = false
        return nil, err
    end

    Api.logged_in = true
    Api.username = data.username or username

    -- 凭据落盘: 源 B 的 Cookie 有效期很短, 需要能自动重新登录。
    -- **只走 SecretStore** —— config.json 里不允许出现明文密码/账号。
    SecretStore.set("jm_account", username)
    SecretStore.set("jm_password", password)
    -- 标记"这份 Cookie 是登录后保存的": 匿名浏览也会下发 Cookie, 不能只看
    -- Cookie 非空就判定已登录 (见 Api.hasSavedSession)。
    config:set("jm_session", true)
    Api.saveCookies(true)

    -- 刷新图片 CDN (登录后可用线路可能变化)
    Api.ensureImgHost(true)

    return {
        username = Api.username,
        uid = data.uid,
    }
end

function Api.logout()
    Api.cookies = {}
    Api.logged_in = false
    Api.username = nil
    cookie_fp = ""
    Api._session_loaded = true
    SecretStore.clear("jm_cookies")
    SecretStore.clear("jm_account")
    SecretStore.clear("jm_password")
    config:set("jm_session", nil)
end

--- 从磁盘恢复的用户名 (用于界面显示 / 自动重登)
function Api.getUsername()
    local name = SecretStore.get("jm_account")
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

--- 磁盘上是否存有可用于**自动重新登录**的凭据
function Api.hasSavedCredentials()
    return Api.getUsername() ~= nil and SecretStore.get("jm_password") ~= nil
end

--- 是否已登录
-- 注意: Api.logged_in 只是内存里的会话标志, 重启后必然为 false,
-- 但磁盘上的凭据/会话仍然有效。只看 logged_in 会误判成"未登录",
-- 从而走不到自动重登分支, 也读不到保存的会话。
function Api.isLoggedIn()
    Api.ensureSessionLoaded()
    return Api.logged_in == true
        or Api.hasSavedCredentials()
        or Api.hasSavedSession()
end

--- 使用已保存的凭据自动重新登录 (会话过期或进程重启后调用)
function Api.reLogin()
    local account = Api.getUsername()
    local password = SecretStore.get("jm_password")
    if not account or not password or account == "" then return false end
    local info = Api.login(account, password)
    return info ~= nil
end

function Api.getFavorites(page, _sort)
    page = page or 1
    -- 取收藏是**主线程同步**等网络: 真机实测一次 7.2s (含域名发现), 期间整页
    -- 不响应输入。缓存后重复进入是 0 秒; 第一次仍然要走网络, 但域名发现已经
    -- 不再重复跑 (见 ensureDomain 的快路径)。
    return cached("jm:fav:" .. tostring(page), CACHE_TTL.FAVORITES, function()
        return Api._getFavorites(page)
    end)
end

--- 真正去服务端取收藏 (缓存未命中时)
function Api._getFavorites(page)
    -- 收藏列表与收藏动作使用同一路径（参数不同）。
    -- 之前返回 401 是因为**会话 cookie 没被吸收**(见 absorbCookies),
    -- 与路径无关；带上会话后能正常返回列表。
    local data, err = Api.get("/favorite?page=" .. tostring(page or 1) .. "&folder_id=0&o=mr")
    if not data then return nil, err end

    -- 兼容两种返回形态: {list=...} 或直接数组
    local list = data.list or data.content
    if type(list) ~= "table" and type(data) == "table" and data[1] ~= nil then
        list = data
    end
    local comics = normalizeBriefList(list or {})
    local total = JN.num(data.total, #comics)
    -- 服务端按 count 返回每页条数, 用它算总页数更准
    local per = JN.num(data.count, 0)
    if per <= 0 then per = math.max(#comics, 1) end
    return {
        comics = comics,
        page = page or 1,
        total = total,
        pages = math.max(1, math.ceil(total / per)),
    }
end

--- 直接问服务端"这本现在收藏了吗" (绕过持久缓存)
-- 用于写操作结果不明时核对真实状态: 收藏接口是**切换**语义, 盲猜会把状态搞反。
function Api.fetchFavoriteState(comic_id)
    local detail = Api._fetchAlbum(tostring(comic_id))
    if not detail then return nil end
    return detail.isFavourite and true or false
end

--- 切换收藏状态
-- 源 B 的 收藏接口是"切换"语义, 先读当前状态再确认结果
function Api.toggleFavorite(comic_id)
    local id = tostring(comic_id)
    local before = Api.album_cache[id]
    if not before then
        before = Api.getAlbum(id)
    end
    local want_fav = not (before and before.isFavourite)

    -- no_retry: **切换**接口不能自动重发。真机 01:06 那次 POST 520 / 522 都是
    -- Cloudflare 的回源失败 —— 请求可能已经在源站生效, 只是响应回不来。自动重发
    -- 会把刚加上的收藏又切回去, 用户看到"点了收藏, 过一会儿又没了"。
    -- 所以这里只发一次; 失败后**先读真实状态**, 确认没落地才补发。
    local data, err = Api.post("/favorite", "aid=" .. id, nil, true)
    if not data then
        local now = Api.fetchFavoriteState(id)
        if now == want_fav then
            if logger.enabled then logger.info("Picayomi SourceB: 收藏请求报错, 但服务端状态已经是目标值 —— 按成功处理") end
            Api.clearListCache()
            return true
        end
        if now == nil then
            -- 连状态都读不到: 如实报错, 别让界面以为收藏成功了
            return nil, err
        end
        -- 状态确实没变: 这次切换没生效, 补发一次 (这次允许换域名)
        if logger.enabled then logger.info("Picayomi SourceB: 收藏未生效, 换域名补发一次") end
        data, err = Api.post("/favorite", "aid=" .. id)
        if not data then return nil, err end
    end

    -- 返回值 type 为 add / del; 与期望不一致时再切一次
    local now_fav = (data.type == "add") or (data.type ~= "del" and data.type ~= nil and tostring(data.type):find("add") ~= nil)
    if data.type == nil then
        now_fav = want_fav   -- 服务端没有明确返回, 默认按切换处理
    end

    if now_fav ~= want_fav then
        data, err = Api.post("/favorite", "aid=" .. id)
        if not data then return nil, err end
    end

    if Api.album_cache[id] then
        Api.album_cache[id].isFavourite = want_fav
    end

    -- 收藏状态变了, 列表/详情的缓存要失效, 否则返回收藏页还是旧的
    Api.clearListCache()
    return true
end

--- 读当前收藏状态 (拿不到就返回 nil, err —— 不能猜)
local function currentFavorite(id)
    local before = Api.album_cache[id]
    if before then return before.isFavourite end
    local album, err = Api.getAlbum(id)
    if not album then return nil, err or "无法确认收藏状态" end
    return album.isFavourite
end

--- 加入收藏 (设定语义: 已经是目标状态就什么都不做)
--
-- 源 B 只有**切换**端点, 所以必须自己先看状态再决定要不要发请求 ——
-- 直接发会变成"再按一次取消"。
function Api.addFavorite(comic_id)
    local id = tostring(comic_id)
    local fav, err = currentFavorite(id)
    if fav == nil then return nil, err end
    if fav then return true end
    return Api.toggleFavorite(id)
end

--- 取消收藏 (设定语义: 已经是目标状态就什么都不做)
function Api.removeFavorite(comic_id)
    local id = tostring(comic_id)
    local fav, err = currentFavorite(id)
    if fav == nil then return nil, err end
    if not fav then return true end
    return Api.toggleFavorite(id)
end

--- 下载图片 (复用源的 downloadImage 实现, 这里只暴露请求头)
function Api.imageHeaders()
    return Headers.imgHeaders()
end

return Api
