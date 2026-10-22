# PicaYomi MangaSources

[PicaYomi 插件](https://github.com/UFOAlastor/koreader_PicaYomi)的独立漫画源与制作资料。平台请求、解析、认证及图片处理在源包内，阅读器、下载、存储和 SDK 在插件内。

当前为私有发布流程预演。`packages/` 是从本次源代码构建的独立 `.pysource`，`SHA256SUMS` 用于核对摘要；不是签名订阅，也尚不能保证普通设备可直接访问私有仓库。正式开放由维护者另行决定。

## 安装

下载所需 `.pysource`，在 PicaYomi 设置 → 源管理 → 导入源包中长按选择，核对发布者后确认信任，重启 KOReader。插件不附带源。三个历史源首次安装需明确授权其使用对应的旧账号、收藏与阅读数据；已有历史源仍通过绑定的签名订阅更新。

| 源 | 浏览与阅读 | 收藏 |
|---|---|---|
| picacg | 需登录 | 源站 / 本地 |
| jm | 需登录 | 源站 / 本地 |
| htcomic | 可免登录 | 本地 |
| copymanga | 可免登录，提供网站账号登录 | 网站账号 / 本地 |

以各源 manifest 的版本与最低宿主要求为准。平台地址在源详情中配置。账号收藏等完整账号场景仍有验收缺口；拷贝只读评论暂缺可用接口。结构检查和离线测试不代表真实平台全链路可用。

## 制作与构建

AI 和维护者先读 [AGENTS.md](AGENTS.md)，再按 [制作指南](docs/AUTHORING.md)、[SDK 契约](docs/CONTRACT.md)、[拷贝案例](docs/COPYMANGA.md)、[测试](docs/TESTING.md)和[发布规则](docs/PUBLISHING.md)工作。

本仓库路径设置：

```sh
PYSOURCE_KIT=.
PYSOURCE_ROOT=sources
python3 tools/build_source.py sources/copymanga --out dist/sources
cp -R templates/api-v3 sources/mysource
python3 tools/build_source.py sources/mysource --out dist/sources
```

需要 Python 3、LuaJIT；签名另需 cryptography。模板使用虚构协议，不能作为真实源发布。运行检查还需要兼容的插件和 KOReader 运行时，不包含在本仓库。

发布源版本不可修改原内容；适配变更升级源版本，新增 SDK 能力才要求更新宿主。`tools/` 仅保留源构建与契约检查的必要工具。测试响应须脱敏，密钥、个人阅读内容与账号状态不进入仓库。许可证状态见 [THIRD_PARTY.md](THIRD_PARTY.md)。
