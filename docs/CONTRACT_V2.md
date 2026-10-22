# SDK 与源契约速查（API v2）

本页可随源仓库独立发布，不依赖私有计划。适用基准：PicaYomi 0.10.0 起；新增宿主接口时必须重新核对兼容版本。

## 包与元数据

`.pysource` 是 UTF-8 JSON：`{format:1,manifest:{...},files:{"main.lua":"Lua 文本"}}`。使用构建工具生成，不手工写 JSON 转义。

| 字段 | 规则 |
|---|---|
| id | 小写字母开头，其后小写字母/数字/下划线/连字符，最多 80 字节；全局稳定 |
| name / author | 非空；名称最多 160 字节，作者最多 200 字节 |
| publisher_id | API v2 必填，稳定发布者身份；字母/数字/下划线/点/连字符，最多 100 字节 |
| version | 三段数字，如 1.0.0；同版本内容不可变，不使用预发布后缀 |
| api_version / min_app_version | 新源 api_version=2，最低宿主按实际依赖填写；可选 max_app_version |
| entry | 包内 Lua 路径，如 main.lua |
| identity_policy | 新源为 stable；legacy 仅供宿主可信迁移的三个历史 ID |
| settings | 最多 16 项 `{key,title,default}`；default 为字符串，不放凭据 |
| data_schema_version | 正整数；不兼容变化在宿主没有迁移器时会拒绝更新 |
| cache_schema_version | 正整数；隔离 API 缓存，不清除阅读记录或主动下载 |

最多 64 个 Lua 文件，包最多 2 MiB；路径不得绝对路径、穿越或大小写冲突，不接受字节码。构建不等于执行级契约验收。`picacg`、`jm`、`htcomic` 是保留 ID；不要用更换身份冒充已有源。

## 工厂与 SDK

入口返回 `function(ctx)`，工厂返回 `ctx.base:extend{capabilities={...}}` 的源对象。宿主设置 identifier/name/version 并调用 `init`；源在初始化期间不得联网。

| SDK | 调用方式与用途 |
|---|---|
| ctx.base | 源基类 |
| ctx.http | `:get(url,headers,timeout)` 返回 response/err；response 含 status_code/body。还提供宿主支持的 post/download 等方法 |
| ctx.json / ctx.html / ctx.aes | rapidjson、HTML 解析、通用 AES；别假设浏览器或 JS 引擎可用 |
| ctx.getSetting | `ctx.getSetting(key,default)` 获取用户文本配置 |
| ctx.config | `:get(key,default)` / `:set(key,value)`，按源隔离 |
| ctx.secrets | `.get/.set/.clear/.get_json/.set_json(key,...)`，使用点调用，宿主加密保存 |
| ctx.require | `ctx.require("api")` 读取包内 api.lua |
| ctx.module | `ctx.module("post")` 返回带源摘要的完整模块名，供 worker 描述符使用 |
| ctx.host | 仅使用宿主明确允许的模块；`ctx.host("util.cache")` 返回隔离缓存，其方法用冒号调用 |
| ctx.logger | 日志接口；不输出凭据或完整个人数据 |

HTTP 通过宿主边界交由可取消任务处理；解析仍在父进程。不要在源中另起常驻后台任务或自己开 socket。模块命名空间属于依赖隔离，源仍是用户信任的可执行代码。

## 必需接口与返回

| 接口 | 结果 |
|---|---|
| init() | 只初始化依赖与本地状态，不取数 |
| getComics(page,sort) | `(true,{comics={...},page,pages,total})` |
| getComicDetail(comic_id) | `(true,{_id,title,thumb,description,...})` |
| getChapters(comic_id,page) | `(true,{episodes={...},page,pages,total})` |
| getAllChapterImages(comic_id,chapter_order) | `(true,{images={"https://...",...}})`，完整有序列表 |
| imageHeaders(url) | 请求头 table；由父进程现算 |

失败统一为 `(false,nil,err)`，收藏增删是 `(ok,err)`。真正的空列表可以成功返回；HTTP/解析/认证失败不能转换为空列表成功。JSON null 不能直接按 Lua nil 理解，先检查字段类型。

图片列表可由源返回 URL 字符串，或带 `url` 的对象。0.10.4 起加载器统一转换为 `{url="https://..."}` 记录后再交给阅读调度、图片后处理和离线下载；已有记录的附加字段保留，不修改源缓存。旧宿主有字符串列表未转换的缺陷，应升级到 0.10.4。图片必须为连续数组，空地址、错误类型及畸形条目明确失败。通过加载器调用图片接口后，消费者读取 `data.images[i].url`，不能仍按字符串下载。

作品条目至少 `_id` 和 `title`，封面使用 `thumb`。新章节至少 `_id` 和 `title`；章节 ID 是平台稳定字符串，最长 160 字节，只用字母、数字、下划线、连字符。同一作品内唯一。加载器补 `order="c_".._id` 与 `sort_index`；`getAllChapterImages` 收到的是这个 order，不能当数组下标。

## 可选能力矩阵

| 能力 | 开启后必须实现 |
|---|---|
| recommendations | getRecommendations(page,sort)，与最新分开 |
| latest | getLatest(page,sort)，可以与基础列表共用真正的最新接口 |
| search | search(keyword,page,sort,categories) |
| categories | getCategories() 返回 `(ok, {_id,title} 数组, err)`；getCategoryComics(category_id,page,sort) 返回标准 comics 容器 |
| rankings | getRankingTypes() 同步返回 `{id,title}` 数组；getRankings(type_id,page) 返回标准 comics 容器 |
| login | login、logout、isLoggedIn、getUserProfile |
| favorites | getFavorites、addFavorite、removeFavorite，增删保证请求状态 |
| comments | getComments，返回 comments/page/pages/total |
| download | getAllChapterImages、imageHeaders |
| local_favorites | 使用宿主本地收藏，无需伪造平台收藏 |

未声明的能力关闭；继承的失败默认方法不算真实实现。`requires_login=true` 必须同时 `login=true`。仅部分功能需登录可用 `access={comments="login"}`。评论回复声明 `replies="none"/"embedded"/"paged"`，后两者要求 comments=true；paged 还须 getCommentReplies，embedded 把 replies 放入评论条目。

普通漫画列表（搜索、排行、收藏等）使用 comics 容器；分类、排行类型和排序项是各自的元数据数组。`getSortOptions(kind)` 的 kind 为 recommend/latest/category/search，返回 `{value,text}` 数组。未知可选能力会导致 v2 激活失败；random 仅兼容保留，当前没有主页入口。

评论与回复都是只读能力：有接口时显示，没有接口时隐藏。所有源都不实现发表、回复或其他写评论操作；这不影响正文查看、评论分页和已存在回复的浏览。

新增源复用宿主首页、分类、排行、搜索、详情、评论和阅读页面，不提供源包自定义 UI。分类/排序/榜单的 ID 与名称由源返回，不依赖宿主注册表。当前没有任意多条件筛选表单、浏览器 JS 或交互式验证码 SDK；需要这类能力时明确提出通用宿主扩展，不能伪造现有接口。

图片处理若需要后处理描述符，使用 `{module=ctx.module("post"),fn="apply"}`，不要写另一个源的模块路径。数据、状态、阅读缓存迁移由宿主负责，源更新只准备 pending，重启激活。
