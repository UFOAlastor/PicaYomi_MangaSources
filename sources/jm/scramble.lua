local ctx = assert(ctx, "source SDK context required")
-- source/jm/scramble.lua
-- 内置源 B 的正文图片还原
--
-- 源侧对部分图片做了分带重排，未还原时表现为横带错位。
-- 分带数与搬运规则由本文件内部的 getNum / decode 系列函数处理；
-- 判据与阈值也只在这里维护，不要在 UI 或缓存层重复实现。
--
-- 具体参数与边界条件见函数实现与测试用例。
--
-- **还原在哪里做** (0.9.7 改): 在**渲染期、内存里**做, 不再在下载子进程里
-- "解码 -> 重排 -> 重新编码 PNG 覆盖原文件"。原因是实测: 真机上一页的后处理
-- 要 3.7~3.9 秒, 其中 3.5 秒是 lodepng 重新压缩一张 1280x1808 的灰度照片
-- (同一份数据在 Mac 上是 99ms / 整页 129ms, 而真机整页 5.2s)。
-- 重排本身只是 18 次整块内存搬运 (Mac 上 <1ms)。为了一次重排去重新编码一张
-- 照片, 是整条阅读链上最贵的一笔浪费 —— 而且它还多占一份缓存。
-- 现在缓存里存的就是源站的原始文件, 解码后当场重排, 页耗时从 5.2s 降到 ~1.3s。


local Scramble = {}

-- 分带规则的两个临界点
local SCRAMBLE_268850 = 268850
local SCRAMBLE_421926 = 421926

--- 计算分带数; 0 表示该图未被混淆
-- @param aid      图片 URL 中的作品/章节号
-- @param filename 图片文件名, **不含扩展名** (如 "00001")
--                 这一点极易写错: 参考实现的 of_file_name(url, True) 带
--                 trim_suffix=true, 即去掉扩展名后再拼进 md5。用带扩展名的
--                 "00001.webp" 会算出完全不同的分带数, 画面依旧是错的。
function Scramble.pieceCount(aid, filename)
    aid = tonumber(aid)
    if not aid then return 0 end
    if aid < SCRAMBLE_268850 then return 10 end

    local x = aid < SCRAMBLE_421926 and 10 or 8
    local digest = ctx.hashes.md5(tostring(aid) .. tostring(filename or ""))
    local last = digest:sub(-1)
    local byte = string.byte(last)
    if not byte then return 0 end
    return (byte % x) * 2 + 2
end

--- 从图片 URL 解析出 aid 与**去扩展名**的文件名
-- 只需要 /media/photos/<aid>/<filename> 这一种; 封面 (/media/albums/) 不走这里
function Scramble.parseUrl(url)
    if type(url) ~= "string" then return nil end
    local aid, filename = url:match("/media/photos/(%d+)/([^/]+)$")
    if not aid then return nil end
    -- 去掉扩展名: 分带数的 md5 输入不含它 (见 pieceCount 的说明)
    local stem = filename:gsub("%.[^%.]+$", "")
    return tonumber(aid), stem
end

--- URL -> 分带数 (0 = 不是正文图 / 无需处理)
function Scramble.countForUrl(url)
    local aid, filename = Scramble.parseUrl(url)
    if not aid then return 0 end
    return Scramble.pieceCount(aid, filename)
end

--- 按分带数把整页重排成新的一张 (纯几何, 不碰 URL / 不碰文件)
--
-- 输入输出的行是**一一对应**的: 目标第 i 带来自源第 (num-1-i) 带, 而多出来的
-- over 行 (h % num) 永远跟着最上面那一带走。分区是完整的 (两边的区间都正好铺满
-- [0,h)), 所以输出不存在未初始化的行。
--
-- @param bb  已解码的整页 BlitBuffer (任意类型/缩放档位)
-- @param num 分带数 (>= 2)
-- @return out_bb 或 nil, 原因
function Scramble.reorder(image,num)
    local ok,out=pcall(ctx.images.reorderBands,image,num)
    if not ok then return nil,"invalid_band_geometry" end
    return out
end

--- 在内存里把分带混淆的页还原成新的一张 (不写文件、不重新编码)
--
-- 调用方负责: 成功时释放**输入** bb (本函数不释放, 因为它可能被别处引用),
-- 以及最终释放返回的 bb。失败返回 nil + 原因, 调用方应继续用原图
-- (花掉的图也比整页空白好)。
--
-- 分带数按**这张图自己的高度**算: 缩放解码出来的是等比缩小的一张图, 分带边界
-- 也随之等比移动; 用 floor(h/num) 重算会有至多 1 像素的偏差 —— 在墨水屏上看
-- 不出来, 但比"为了精确而放弃缩放解码"划算 (那会把大图解码量翻几倍)。
--
-- @param bb  已解码的整页 BlitBuffer (任意类型/缩放档位)
-- @param url 图片地址 (用来算分带数)
-- @return out_bb 或 nil, 原因
function Scramble.applyTo(bb, url)
    if not bb then return nil, "no_bitmap" end
    local num = Scramble.countForUrl(url)
    if num <= 0 then return nil, "not_scrambled" end
    return Scramble.reorder(bb, num)
end

-- Non-secret replay data survives URL expiry and offline file renaming.
function Scramble.applyContext(bb, context)
    return Scramble.reorder(bb,context and context.bands)
end

return Scramble
