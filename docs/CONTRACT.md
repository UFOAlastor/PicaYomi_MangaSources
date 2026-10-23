# SDK 与源契约（API v3）

适用宿主：PicaYomi **0.10.6 起**。新源使用 `templates/api-v3`。公开制作资料仅维护当前 API v3。源仍是用户信任的 Lua 代码，SDK 不是安全沙箱。

## 包与生命周期

容器仍是 UTF-8 JSON `{format:1,manifest,files}`，最多 2 MiB / 64 个 Lua 文本文件。manifest 的 ID、发布者、版本、路径、settings、数据与缓存版本规则沿用 v2；新包明确 `api_version=3`、`min_app_version>=0.10.6`。同版本内容不可变。新源用 stable 身份，不得占用历史源保留 ID。

入口返回 `function(ctx)`，工厂返回普通表 `{capabilities=...,access=...}`，无需继承基类。工厂、模块顶层、`init(ctx)` 均禁止联网。init 恢复本地状态并注册处理器，返回 `(true,{success=true},nil)`。宿主只初始化一次，固定包摘要；更新为 pending，重启激活。初始化成功不代表真实平台可用。

## 返回值与模型

所有业务方法返回 `(true,data,nil)` 或 `(false,nil,SourceError)`，成功 data 不能为 nil，写操作成功为 `{success=true}`。失败不能伪装为空列表或部分目录/图片。空浏览与空目录合法，零页章节不能开始阅读。

`SourceError={code,message,retryable,operation?,field?}`，通过 `ctx.error(code,message,operation,field,retryable)` 构造。code 为 unsupported、auth_required、auth_expired、network、timeout、rate_limited、not_found、protocol_changed、invalid_response、cancelled、resource_limit。message 不带凭据、完整认证 URL 或个人响应；宿主不匹配文案决定重试或登录。

| 模型 | 字段 |
|---|---|
| Manga | `id`、非空 `title`；可选 `cover/author/description/updated_at` 字符串、`tags/categories` 字符串数组、`finished/favorite`；`stats={chapters?,pages?,likes?,comments?,views?}` 为非负整数；0.10.8 起可带 `metadata` 展示用文本对象 |
| Chapter | `id/title`；宿主补 `manga_id` 与连续显示 `position`；可选 `page_count`。迁移专用 legacy_order 由可信身份映射使用，新源不使用 |
| ListResult | 连续数组 `items`、布尔 `has_more`；true 必须提供非空 `next` 对象，false 不提供 next；准确 total 可选 |
| PageList | 连续数组 `items`、`complete=true`，必须是完整章节 |
| Page | 从 1 连续递增的 `index`、`resource={url}`；可选 context、`processors={file?,render?}` |
| Comment | `id/content/author`，author 是对象；可选 created_at、likesCount、repliesCount、内嵌 replies |
| 元数据 | 分类、榜单和排序使用 `{id,title,...}` 数组，分类可带 isWeb/link |

ID 是最长 512 字节的非空 UTF-8 不透明字符串，可含平台分隔符；宿主转换存储键，源不接触文件路径。标题最多 4096 字节。每个列表最多 20000 项；复制最多 200000 节点、12 层、普通单字符串 256 KiB、单批累计文本与键 8 MiB。只接受 JSON 数据，不接受函数、任意元表、循环、userdata 或 JSON null；rapidjson 的 array/object 标记可用。结果经校验和深拷贝后进入消费者，不修改源缓存。

context/next 最多 16 KiB，为有界 JSON 对象。禁止凭据、请求头、模块引用、URL 和本地路径；宿主拒绝已知敏感键，作者仍须保证自定义字段不藏秘密。只保存处理所需数据，如 `{bands=12}`。

## 方法与分页

以下方法最后一个参数均为宿主 call，上下文含 deadline（墙钟秒）、cancelled、可选 isCancelled() 和代次信息。源不保存或修改 call，它与持久化 page context 分开。

| 接口 | 结果与能力 |
|---|---|
| `getManga(id,call)` | Manga，必需 |
| `getChapters(id,request,call)` | ListResult<Chapter>，必需；宿主汇集完整目录后发布 |
| `getPages(manga_id,chapter_id,call)` | PageList，必需；chapter_id 是平台 ID，没有存储前缀 |
| `getImageRequest(resource,page_context,call)` | ImageRequest；可省略，宿主提供普通 GET 默认实现 |
| `getLatest(request,call)` / `getRecommendations(request,call)` | ListResult<Manga>，latest / recommendations 独立开启 |
| `search(keyword,request,call)` | ListResult<Manga>，search |
| `getCategories(call)` / `getCategoryComics(id,request,call)` | 分类数组 / ListResult<Manga>，categories |
| `getRankingTypes(call)` / `getRankings(id,request,call)` | 榜单数组 / ListResult<Manga>，rankings |
| `getSortOptions(kind,call)` | 排序数组；可省略，默认空；kind 为 recommend/latest/category/search |
| `login(username,password,call)` / `logout(call)` | `{success=true}`，login |
| `getSession(call)` / `getUserProfile(call)` | `{logged_in=boolean}` / 资料对象，login |
| `getFavorites(request,call)` / `addFavorite(id,call)` / `removeFavorite(id,call)` | 列表 / 明确设定状态的成功结果，favorites |
| `getComments(id,request,call)` / `getCommentReplies(id,comment_id,request,call)` | ListResult<Comment>，只读 comments / paged 回复 |

首轮 request 不带续页字段；后续合并上一轮 next 的不透明内容，可带 sort/categories。例如 next={cursor="abc"}，下次接收 {cursor="abc",sort=...}。不要假定只有页码。未知总量不填 total，不伪造 pages，界面按 has_more 翻页。目录最多 200 次请求 / 20000 章，拒绝重复 continuation/ID，取消或失败不发布部分结果。

宿主 **0.11.20 起**，作品列表可额外声明 `pagination={mode="page",page=1,pages=695,page_size=20}`，仅用于源站确实支持任意页码定位并提供末页的接口。三个数字须为正整数，页码与末页最多 1000000、每页容量最多 20000；page 不超过 pages，has_more 等于 page<pages，续页只能是 `{page=page+1}`。宿主按查询/排序隔离声明，验证成功后允许在范围内直接跳页，不受游标遍历的 200 页上限影响；仍只保留有界续页状态。`page_size` 是固定每页容量，末页不足整页时不缩小。只有分页器末页、没有准确条数时不填 total；不依赖额外游标的页码源才能使用此扩展，并须声明最低宿主 0.11.20。其他源继续使用不透明 next，不从普通 `{page=...}` 续页推断支持跳页。

能力键：login、requires_login、recommendations、latest、search、categories、rankings、favorites、comments、download、local_favorites；random 是兼容保留接口，没有首页入口。未声明关闭，未知键或缺实现激活失败。requires_login 要求 login；部分功能登录用 `access={favorites="login"}`。replies 为 none/embedded/paged，后两者要求 comments。评论仅只读，所有源不实现发表。

宿主 0.11.5 起，未登录也可进入主页、切源、设置及离线入口；`requires_login` 与 `access` 约束具体在线动作，不应将支持账号等同于整个插件必须登录。

## 列表展示配置（宿主 0.10.8 起，可选）

源工厂可声明 `list_display`，选择两行信息的字段、顺序和标签。没有配置时完全沿用宿主默认展示，不影响已发布 v1/v2/v3 包。使用此扩展的包必须声明 `min_app_version>=0.10.8`，当前 v3 模板已声明这个版本。

```lua
local source={capabilities={latest=true},list_display={
    subtitle={"author","categories"},
    details={"finished",{field="metadata.heat",label="热度"},"updated_at"},
}}
-- 在作品中返回：metadata={heat="123.4W"}
```

可选字段：`author/categories/tags/finished/updated_at/subtitle`、`stats.chapters/pages/likes/views/comments` 和 `metadata.<key>`。每行最多六项，可写字段字符串或 `{field=...,label=...}`，不接受代码、任意格式模板或界面控件。缺失字段跳过，不编造作者、日期、计数或状态；配置为空的行保持空白。标准字段仍按原类型返回，不能为了显示而把热度伪装成阅读量。标签最多 64 字节，无控制字符。

`metadata` 最多 16 个键，键为不超过 64 字节的 `[a-z][a-z0-9_]*`，值为不超过 512 字节的非空文本，不含控制字符。平台原始字段名与枚举含义由源解释，列表不得逐本请求详情来补信息。宿主校验并固定工厂的配置，受控投影携带 `_list_display`；源结果不能自行覆盖这个内部字段。配置和返回数据均深拷贝，消费者修改不会污染源缓存。下载进度与跨源标识仍由宿主追加，行高和触控布局由共享控件管理。

## 具名 SDK 服务

v3 没有 ctx.host、ctx.base、ctx.module；通过 `ctx.require("api")` 导入本包模块。

| 服务 | 调用约定 |
|---|---|
| ctx.http | 冒号调用 get(url,headers,timeout)、post(url,headers,body,timeout)、requestWithRetry(method,url,headers,body,timeout)，返回 response/err，response 含 status_code/body。沿用宿主可取消任务和网络策略；超时受 call deadline 与 60 秒上限约束，不自行开 socket/后台进程 |
| ctx.json / ctx.html | decode/encode；parse(html) 与节点 select/textonly。JSON null 用 ctx.values 处理，不返回宿主 |
| ctx.values | str/num/bool/list/str_list，带缺省值的 JSON 字段读取辅助 |
| ctx.aes / ctx.b64 / ctx.hmac / ctx.hashes | 通用加解密/编码；hashes 的 md5/sha256 返回十六进制字符串，不包含平台协议常量 |
| ctx.config | 冒号 get(key,default)/set(key,value)，按源隔离；历史源由宿主映射已授权旧键 |
| ctx.secrets | 点调用 get/set/clear/get_json/set_json(key,...)，宿主加密保存 |
| ctx.cache | 冒号 getData/cacheData/clear/clearPattern，按源与 cache_schema_version 隔离；cacheData 第三参数为到期时间戳 |
| ctx.getSetting | 点调用 (key,default) 读取用户文本设置，凭据不放 settings |
| ctx.text / ctx.translate | htmlToPlainText/htmlEntitiesToUtf8/template；翻译函数，无宿主窗口 |
| ctx.cookie | Cookie 解析、合并和请求头序列化，不负责跨源转发 |
| ctx.clock | 点调用 now() 墙钟秒、timestamp() 整数时间戳 |
| ctx.logger / ctx.redact / ctx.trace | 脱敏日志与最小诊断；作者仍不应传入个人响应或秘密 |
| ctx.error / ctx.imageRequest | 错误构造；imageRequest(resource,headers,timeout) 返回成功 GET 三元组 |

服务沿用宿主实现。浏览器 JS、验证码交互、任意宿主模块和自定义 UI 不在本契约。平台 HTTP 的证书和跨域认证头加固是独立待办，本版不声称已完成。

## 图片处理与离线

ImageRequest 为 `{url,method="GET",headers={},timeout?}`：仅 HTTP(S)，不接受 userinfo、空白或控制字符；URL 最长 16 KiB，最多 64 个请求头 / 32 KiB，头名和值为无控制字符的字符串，超时最多 60 秒。父进程在实际派发时调用，源此时读取最新会话，headers 不进入页面或离线清单。目标文件、并发和优先级由宿主控制。

在 init 注册 `ctx.images.register("bands",{stage="render",module="processors",fn="bands",version=1})`，仅限本包模块，初始化后封存。页面声明 `processors={render={name="bands",version=1}}`，宿主绑定源 ID、完整摘要、阶段和 context。文件转换注册 stage=file，同一页可有两阶段。

- render 接收 `(image_handle,context)`，返回图片句柄。dimensions(handle) 读尺寸，reorderBands(handle,n) 返回新图，n 为 2..512 且不超过高度。宿主管理释放，每次处理最多生成一个输出，源不调用 BlitBuffer；输入加输出纳入解码预算。图片和文件句柄仅在本次处理调用中有效，返回后撤销，不能保留到后续请求。
- file 接收 `(file_handle,context)`，使用 readFile(handle,limit) 和 writeFile(handle,bytes)，两者最多 2 MiB，成功返回 true。宿主受控临时写入后原子提交并验证图片；失败不提交成功状态。
- 必需处理失败显示明确错误，不展示未处理原图。模板 processors.lua 演示 base64 文件转换和分带重排。

离线清单格式 2 新增处理、内容指纹、就绪状态与已提交文件记录，首次改写前备份格式 1。续传只复用匹配且就绪的文件，文件转换不重复执行，离线重开只重放 render；旧扩展名残留不参与页面选择。必要包按完整摘要保留，禁用或卸载后仍可在新进程加载；清单损坏不触发包回收或覆盖原文件。旧 JM 下载缺少上下文时保留并标为可重试的部分下载。主程序降级与源回滚分开：旧宿主不理解新的离线重放信息，不能把 JSON 可读当作图片正确可读。

迁移四源的可选 getCredential/setCredential、punchIn 仅服务既有认证兼容入口，也返回标准三元组，新源不依赖这些历史接口。迁移权限不能靠修改 id/publisher_id 获得。

## 诊断日志（宿主 0.11.2 起）

`ctx.logger.enabled` 与 `ctx.trace.enabled` 为宿主进程启动时确定的布尔值。发布默认关闭 info/dbg 与 trace；源应在调用前检查开关，跳过字符串拼接和格式化。warn/err 保留；日志不能包含账号、密码、会话或完整响应。使用该门控接口的源声明 min_app_version 至少 0.11.2；旧源仍可调用日志，但其预先计算参数的成本无法由宿主取消。
