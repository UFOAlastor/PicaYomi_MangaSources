# 源版本、订阅与维护

普通作者先生成 `.pysource`，用户通过设置 → 源管理 → 导入源包，长按选文件，确认信任后重启。无需把源文件手动放入插件内部路径。

## 版本与本地产物

源版本独立于宿主。改域名候选、字段解析、请求或图片处理都升级源版本；同版本内容不可修改。新增宿主依赖才抬高 min_app_version。稳定 id/publisher_id 与章节身份不能随普通更新改变。

```sh
python3 tools/build_source.py "$PYSOURCE_ROOT/mysource" --out dist/sources
```

本地无订阅目录的构建成功后，按源 ID 只留最新 `.pysource`；失败保留原包，不能在含新版的同一输出目录回建旧版。不同源互不删除。需要比较旧版时使用单独临时目录。

正式发布使用独立 `releases/<publisher>/`，不要把它当可随意清理的本地 dist。签名目录可同时保留多个兼容发行版，其仍引用的文件属于当前发行集合；构建器不会删除这些文件，否则旧客户端会遇到失效链接。移除旧发行版本须先形成新的合法目录并确认兼容策略。

## 当前分发方式

本仓库的 `packages/` 提供手动安装包及 SHA256SUMS，没有预置的签名订阅地址。GitHub 仓库链接和 SHA256SUMS 不能直接作为订阅目录添加。

历史三源的已有安装需要绑定签名订阅才能更新；首次导入与更新采用不同的身份规则。建立订阅时按发布者提供完整目录、不可变包及签名，并在客户端验证绑定与更新。

## 签名目录

签名工具另需 Python cryptography。发布密钥是外部 Ed25519 PEM，不放进源码、fixture、安装包或公开仓库。实际密钥生成与使用按维护者明确的发布指令操作，教程不提供任何有效密钥。

```sh
python3 tools/build_source.py "$PYSOURCE_ROOT/mysource" \
  --out releases/community.mysource \
  --base-url https://sources.example/mysource \
  --sign-key /path/outside/repository/publisher.pem --revision 1
```

示例域名必须替换为自己的真实 HTTPS 地址。命令只生成包和 index.json，不上传。先上传不可变包，再上传目录。每次目录构建 revision 必须增加；一次目录内所有源使用同一 publisher_id，目录含多个源时每次构建也递增 revision。

当前三个历史源的 publisher_id 为 picayomi.legacy，拷贝为 picayomi.copymanga；不能直接混进同一个签名目录。社区新源使用自己的稳定发布身份，不要冒用这些身份。

原始目录为 format=2，包含 name/publisher_id/revision/sources；每项包含 id、版本、兼容范围、URL、sha256、size 与 package signature。外层 `{signed:1,public_key,signature,payload}` 中 payload 是原始 JSON 字符串，不得重新排版后复用签名。公钥为 32 字节、签名为 64 字节的小写十六进制。

签名消息为 `PicaYomi/<purpose>/v1` + NUL + 原始字节；purpose 为 index/package/rotation。正常密钥轮换用 `--rotation-key` 提供旧钥签署新钥，同时为保留包生成新钥签名；旧钥丢失须客户端显式重新确认身份。

旧未签名 format=1 目录只能手动更新。自动安装要求已确认的签名订阅，只更新已安装源，固定版本、兼容范围、撤回与隔离规则仍生效；不能保证开启自动安装后所有客户端立即采用新版。

## 发布前检查

1. 版本、发布者、能力和兼容范围与代码及测试一致。
2. 离线与真实接口结果分开列，缺账号/设备明确标注。
3. 核对代码来源和许可证，fixture 去除个人信息、凭据与非必要阅读内容。
4. 在独立目录验证包摘要、目录签名、所有引用文件、客户端首次添加和更新。
5. 人工审查将公开的文件与变更；获得明确发布指令后上传，并记录真实可访问地址。

后续维护依据响应/结构变动与用户问题，保留最小回归样例。域名失效、章节截断、图片缺页分别诊断，不能一律让用户更新整个插件或清空阅读数据。
