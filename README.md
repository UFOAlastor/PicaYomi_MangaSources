# PicaYomi MangaSources

[PicaYomi 插件](https://github.com/UFOAlastor/koreader_PicaYomi)的独立漫画源、SDK 契约、制作模板与检查工具。平台请求、解析、认证和图片处理由源负责，阅读器、下载、存储及通用界面由插件提供。

## 下载与兼容性

从下表或 [packages](packages) 目录选择源包，使用 GitHub 的 **Download raw file** 保存 `.pysource` 文件；不要将网页另存为源包。

| 漫画源 | 版本 | 最低插件版本 | 源包 | 浏览与阅读 |
|---|---|---|---|---|
| 哔咔漫画（picacg） | 1.1.1 | 0.11.2 | [下载](packages/picacg-1.1.1.pysource) | 需登录 |
| 禁漫天堂（jm） | 1.1.1 | 0.11.2 | [下载](packages/jm-1.1.1.pysource) | 需登录 |
| 绅士漫画（htcomic） | 1.1.1 | 0.11.2 | [下载](packages/htcomic-1.1.1.pysource) | 可免登录 |
| 拷贝漫画（copymanga） | 1.5.0 | 0.10.8 | [下载](packages/copymanga-1.5.0.pysource) | 可免登录，支持网站账号登录 |

源包版本和最低插件要求以对应的 `manifest.json` 为准。平台地址可在源详情中设置；源站访问条件和账号限制可能影响实际使用。

[SHA256SUMS](packages/SHA256SUMS) 可用于核对下载内容。在完整下载本仓库后，可运行：

```sh
cd packages
shasum -a 256 -c SHA256SUMS
```

SHA-256 用于核对文件内容；确认发布者仍需选择可信下载来源。

## 安装与更新

1. 安装兼容版本的 PicaYomi 插件。
2. 将所需 `.pysource` 文件复制到设备的可选目录。
3. 打开 **PicaYomi → 设置 → 源管理 → 导入源包**，长按选中文件。
4. 核对名称、版本与发布者后确认信任，重启 KOReader。

插件不附带漫画源，源包也不包含插件本体。源包是可执行代码，只安装可信来源的文件。

哔咔、禁漫和绅士漫画保留历史身份。首次安装会提示其对对应旧账号、收藏和阅读数据的访问权限；这些源已有安装的更新需要绑定兼容的签名订阅，目前没有预置订阅地址。请勿通过删除账号或阅读数据绕过更新限制。拷贝等普通独立源可按宿主支持的同发布者、同来源和版本规则更新。

当前 `packages/` 提供手动安装包，没有可直接添加的签名订阅目录。源安装、更新、禁用或切换版本后均需重启 KOReader；卸载源会保留已有收藏、历史与下载。

## 功能与限制

- 各源按声明提供推荐、最新、搜索、分类、排行、详情、章节、图片及下载能力。
- 哔咔和禁漫支持源站收藏或本地收藏；绅士漫画使用本地收藏；拷贝支持网站账号收藏和本地收藏，网站账号收藏仍缺完整真实账号验证。
- 评论仅提供查看正文与回复，全部源均不提供发表评论或回复。拷贝源未声明只读评论能力。
- 拷贝的网站会话与历史 App 接口认证分开处理，网站 token 不发送给 App 节点或图片 CDN。
- 离线检查与匿名浏览结果不能证明账号操作、全部作品或所有设备可用。故障反馈请提供源版本、插件版本、复现步骤及脱敏报错。

源适配问题请提交到本仓库的 [Issues](https://github.com/UFOAlastor/PicaYomi_MangaSources/issues)；阅读器和通用界面问题请提交到[插件仓库](https://github.com/UFOAlastor/koreader_PicaYomi/issues)。

## 制作漫画源

AI 和维护者先读 [AGENTS.md](AGENTS.md)，再按以下资料开发和验证：

- [制作指南](docs/AUTHORING.md)
- [API v3 契约](docs/CONTRACT.md)及[旧 API v2 契约](docs/CONTRACT_V2.md)
- [拷贝源适配案例](docs/COPYMANGA.md)
- [构建、样例检查与验收](docs/TESTING.md)
- [版本、签名订阅与发布](docs/PUBLISHING.md)

需要 Python 3 和 LuaJIT；签名发布另需 Python cryptography。所有命令在仓库根目录执行：

```sh
PYSOURCE_KIT=.
PYSOURCE_ROOT=sources
python3 tools/build_source.py sources/copymanga --out dist/sources
cp -R templates/api-v3 sources/mysource
python3 tools/build_source.py sources/mysource --out dist/sources
```

新源须修改模板中的 ID、名称、发布者与平台协议。模板使用虚构响应，只用于学习和检查工具链；运行检查还需单独安装兼容插件和 KOReader 运行时。

适配变更升级源版本，同一版本的发行包保持内容不变。新增宿主能力时再调整最低插件版本。密钥、账号、会话、个人阅读文件和原始日志不进入源包或仓库。代码来源与许可证状态见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 免责声明

本项目仅供学习、研究与技术交流，不内置漫画内容，也不提供内容托管服务。作品版权归原作者及相关权利人所有，请支持正版，勿下载、传播或分享未经授权的资源；误获取的盗版资源请立即删除，临时测试文件请于下载后 24 小时内清理。该时限不构成版权授权或免责依据。使用者应遵守所在地法律法规及内容平台的使用规则，并自行承担使用行为产生的责任。
