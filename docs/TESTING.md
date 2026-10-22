# 构建、离线样例与真实验收

所有命令在仓库根目录开始，按 README 设置 `PYSOURCE_KIT`、`PYSOURCE_ROOT`。以下目录均为本地临时产物，不会自动部署。

## 先验证模板和工具链

```sh
python3 tools/build_source.py "$PYSOURCE_KIT/templates/api-v3" --out /tmp/pysource-template
```

生成 `sdk_fixture-1.0.0.pysource`。LuaJIT 语法检查并不证明工厂、能力与网络协议正确；需要真实宿主加载。

先设置本机 KOReader 运行时与宿主源码路径：

```sh
PYSOURCE_EMU=/path/to/koreader-runtime
PYSOURCE_HOST=/path/to/picayomi-host-checkout
PYSOURCE_CHECK="$(pwd)/$PYSOURCE_KIT/tools/check_source.lua"
PYSOURCE_FIXTURE="$(pwd)/$PYSOURCE_KIT/examples/api-v3-fixture.json"
PYSOURCE_DATA="$(mktemp -d)"

cd "$PYSOURCE_EMU"
KO_HOME="$PYSOURCE_DATA" SDL_VIDEODRIVER=dummy ./luajit "$PYSOURCE_CHECK" \
  "$PYSOURCE_HOST" /tmp/pysource-template/sdk_fixture-1.0.0.pysource "$PYSOURCE_FIXTURE"
```

成功应输出包/激活通过及 fixture case 通过。KO_HOME 必须是隔离目录，避免使用作者已有账户和阅读数据。当前模板要求插件 0.10.8 起；实际源还须满足其 manifest 声明的最低版本。源仓库不包含 KOReader 或插件运行时。

`PYSOURCE_HOST` 指向单独安装的 [PicaYomi 插件](https://github.com/UFOAlastor/koreader_PicaYomi)目录，其中应直接包含 main.lua。运行时系统库、签名依赖和设备兼容分别检查；使用系统 Lua 进行语法检查不能代替 KOReader 加载。

## 给新源写 fixture

示例格式：

```json
{
  "settings":{"base_url":"https://api.example.invalid"},
  "responses":{"https://api.example.invalid/list":{"status_code":200,"body":"{\"items\":[]}"}},
  "cases":[{"method":"getLatest","args":[{}],"expect":{"ok":true,"counts":{"items":0}}}]
}
```

`responses` 精确匹配 GET URL，未匹配时报错；body 是字符串。`expect.data` 检查给定字段的递归子集，数组个数通过 `expect.counts` 检查，失败可用 `expect.code` 检查错误码、`expect.error` 匹配短原因。应同时断言字段、计数和分页，不只验证 ok=true。

检查器只提供 fixture GET；POST/登录、多步骤 token、请求头策略、Cookie、图片后处理和复杂分页需要源专属测试。不要为了通过通用检查器简化平台真实协议。fixture 模式替换 ctx.http，不是恶意代码网络沙箱；源不应绕开 SDK 自己联网。

API v3 的 case 方法通过 SourceRuntime.invoke 调用，使用规范字段。源还需在真实宿主中验证生产阅读、下载及独立进程的离线重开；本检查器的映射断言不代替这些集成场景。

## 验收清单

| 范围 | 需要的证据 |
|---|---|
| 结构 | manifest、文本/路径/大小、兼容范围、工厂和能力激活 |
| 映射 | 标题/封面/详情、真实空结果与错误分开 |
| 分页 | 列表第二页、章节超过单页、提前空页与总数不一致 |
| 身份 | 章节重排/插番外不改变 ID；重复 ID 拒绝 |
| 可选能力 | 无评论隐藏、有评论展示，paged/embedded 回复，登录条件与变化 |
| 故障 | HTTP 错误、超时、无效 JSON/HTML、字段缺失、认证失效；失败不污染有效缓存 |
| 生命周期 | 安装、重启启用、更新保留旧任务、回滚与卸载保留数据 |
| 在线 | 推荐/最新/搜索/详情/全部章节/首图，按已声明功能验证账号操作 |

线上测试单独准备脚本或人工流程；不要在 fixture 模式发真实请求。记录日期、宿主/源版本、样本与每项通过/失败/未执行。首图必须验证真实图片内容，只有 URL 字符串还不够。

涉及宿主的新能力、生命周期或图片处理变更，还需进行插件侧集成验证。没有账号或设备时记录缺口，不删除失败用例或将跳过计为通过。
