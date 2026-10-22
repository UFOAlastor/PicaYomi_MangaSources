# 源版本、订阅与维护

当前公开制作资料使用 API v3，默认订阅使用签名聚合目录 format 3。源包与插件分别维护版本。用户通过插件的订阅管理安装和更新，重启后激活。

## 分发方式

源仓库不需要 GitHub Release。插件直接读取 `packages/index.json`，按其中的 URL 下载不可变 `.pysource` 包。默认目录地址为：

```text
https://raw.githubusercontent.com/UFOAlastor/PicaYomi_MangaSources/main/packages/index.json
```

已有同发布身份的源在默认引导时绑定订阅。默认公钥由宿主预置；用户主动输入其他订阅地址即授权首次信任。后续固定发布身份与密钥，身份变化不能静默接受。

## 版本与产物

改域名、请求、解析或图片处理须升级源版本；同 ID/version 的文件不可改写。新增宿主依赖时调整 `min_app_version`。稳定的源 ID、发布者身份及章节 ID 不随普通更新改变。

```sh
python3 tools/build_source.py "$PYSOURCE_ROOT/mysource" --out dist/sources
```

本地无订阅目录的构建按源 ID 只留最新版；失败保留旧包。正式目录仍引用的所有兼容版本都要保留，不能按临时构建清理。源内容与许可说明随源码维护，账号、密钥、个人阅读文件和日志不进入发行包。

## 签名聚合目录

需要 Python cryptography。私钥为外部 Ed25519 PEM，保存在仓库忽略目录或仓库外，不提交、不上传。密钥生成和轮换按维护者明确指令执行。

```sh
python3 tools/build_catalog.py dist/sources \
  --key /secure/sources-ed25519.pem --revision 2 \
  --base-url https://raw.githubusercontent.com/UFOAlastor/PicaYomi_MangaSources/main/packages \
  --out dist/sources/index.json
```

示例 revision 必须替换为高于已发布目录的数值。命令只生成目录，不上传。

外层为 `{signed:1,public_key,signature,payload}`；payload 是原始 JSON 字符串，不得改写后复用签名。payload 的 `format=3`，包含目录 name/publisher_id/revision/sources；各条目保留自身 publisher_id，并包含 id、版本、API 与插件兼容范围、URL、sha256、size 和 package signature。默认目录发布者为 `picayomi.sources`。

公钥为 32 字节、签名为 64 字节的小写十六进制。签名消息为 `PicaYomi/<purpose>/v1` + NUL + 原始字节；purpose 为 index/package/rotation。同一密钥验证目录与各包。宿主拒绝修订号回退、同修订号内容变化及同源同版本内容变化。

## 发布顺序

1. 完成源包、manifest、离线样例及真实接口检查；缺账号或设备时明确记录未验证项目。
2. 检查许可、公开文件和脱敏情况；生成新版包并核对摘要与大小。
3. 使用维护者的签名密钥生成更高 revision 的目录，验证所有引用文件、签名与兼容范围。
4. **先上传新版本源包，再更新目录**；可在同一 Git 提交中原子发布。保留目录引用的旧兼容版本。
5. 验证匿名 HTTPS 下载、客户端更新及重启激活，记录远端提交与摘要。

源站错误、断网和账号失效不触发代码回滚；初始化失败由宿主内部恢复上一可用版本。用户界面不提供版本固定或手动回滚入口。

自动检查默认关闭。开启后，在首页空闲且已联网时更新已安装的可信签名源，每个 KOReader 进程最多完成一轮，遵守 24 小时间隔与失败退避。成功后提供“立即重启 KOReader／稍后”；自动流程不添加新源或恢复已卸载源。源码改变只有正常重启后才激活。
