# PicaYomi MangaSources

[PicaYomi 插件](https://github.com/UFOAlastor/koreader_PicaYomi)的独立漫画源、SDK 契约、制作模板与检查工具。平台请求、解析、认证和图片处理由源负责，阅读器、下载、存储及通用界面由插件提供。

## 订阅与更新

插件预置本仓库的默认订阅。日常更新通过插件的 **设置 → 源管理 → 更新漫画源（全部订阅）** 完成。

订阅直接读取仓库中的 [`packages/index.json`](packages/index.json)，再下载目录所引用的 `.pysource` 包，**不依赖 GitHub Release**。目录与源包经过签名校验；文件完整性、源身份及插件兼容性由宿主核对。可用版本和最低插件要求以目录及各包的 `manifest.json` 为准。

自动检查更新默认关闭。开启后，在已联网且首页空闲时检查已安装的可信签名源，发现更新先询问，点击“下载更新”才下载；完成后提供“立即重启 KOReader”与“稍后”。无更新不提示，稍后在本次运行中不重复询问；检查或下载失败说明原因。

> 插件 0.11.19 起，成功检查后间隔 6 小时，到期后再次进入联网、空闲主页可检查，无需重启；同版本提示在本次运行中去重，失败退避，手动更新不受冷却限制。取消或异常提前中断可在之后再次尝试。自动流程不添加新源或恢复已卸载的源，切换页面时暂缓提示，返回首页后继续确认流程。
>
> 全部订阅删除后，可在订阅管理中点击“恢复默认订阅”。

[SHA256SUMS](packages/SHA256SUMS) 可用于核对文件内容：

```sh
cd packages
shasum -a 256 -c SHA256SUMS
```

## 功能与限制

- 各源按声明提供推荐、最新、搜索、分类、排行、详情、章节、图片及下载能力。
- 登录、源站收藏、分类和排行等功能取决于各源的能力声明；未声明的功能不会显示入口。
- 绅士源 1.1.3 恢复分类总页数和直接跳页，需要插件 0.11.20 起；保留 1.1.2 的历史封面地址修复。先升级插件并重启，再从源管理更新源，完成后重启生效。
- 禁漫源 1.1.2 修复分类入口的空标识校验错误，仍使用源站原有分类参数；日榜与周榜各自展示源站返回内容。
- 宿主评论列表显示短预览，长评论可点开本地全文浮窗；不提供回复浏览或发表操作。
- 离线检查与匿名浏览结果不能证明账号操作、全部作品或所有设备可用。故障反馈请提供源版本、插件版本、复现步骤及脱敏报错。

源适配问题请提交到本仓库的 [Issues](https://github.com/UFOAlastor/PicaYomi_MangaSources/issues)；阅读器和通用界面问题请提交到[插件仓库](https://github.com/UFOAlastor/koreader_PicaYomi/issues)。

## 制作漫画源

AI 和维护者先读 [AGENTS.md](AGENTS.md)，再按以下资料开发和验证：

- [制作指南](docs/AUTHORING.md)
- [API v3 契约](docs/CONTRACT.md)
- [构建、样例检查与验收](docs/TESTING.md)
- [版本、签名订阅与发布](docs/PUBLISHING.md)

需要 Python 3 和 LuaJIT；签名发布另需 Python cryptography。所有命令在仓库根目录执行：

```sh
PYSOURCE_KIT=.
PYSOURCE_ROOT=sources
cp -R templates/api-v3 sources/mysource
python3 tools/build_source.py sources/mysource --out dist/sources
```

新源须修改模板中的 ID、名称、发布者与平台协议。模板使用虚构响应，只用于学习和检查工具链；运行检查还需单独安装兼容插件和 KOReader 运行时。

适配变更升级源版本，同一版本的发行包保持内容不变。新增宿主能力时再调整最低插件版本。密钥、账号、会话、个人阅读文件和原始日志不进入源包或仓库。项目代码采用 [MIT License](LICENSE)，第三方来源见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 免责声明

本项目仅供学习与技术交流，不提供或托管漫画内容，作品版权归相关权利人所有。请遵守当地法律及平台规则，支持正版，并自行承担使用责任。
