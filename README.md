# InboxCode

原名 CodeDrop。轻量 macOS 邮箱验证码助手：后台通过 IMAP 监听新邮件，提取验证码并自动复制；Raycast 查看各账号最新代码、管理邮箱，桌面可显示紧凑提醒。

支持通用 IMAP，内置 QQ、Gmail、普通 SJTU 配置。使用 TLS 和系统证书验证，当前程序以只读方式访问收件箱。无需日常打开网页邮箱。

也支持密码重置、邮箱确认和登录链接：弹窗右侧显示 `Copy Link`，点击复制完整地址；Raycast 显示服务、收件邮箱和链接域名，回车复制。链接不会自动打开，收到时不自动覆盖剪贴板；验证码仍按原设置自动复制。

## 安装与使用

安装包位于本仓库的 [Releases](https://github.com/Raysance/toolbox/releases)，选择 InboxCode 发布中的 `.rayext` 文件导入 Raycast。打开「管理邮箱」添加账号，填写对应的授权码或应用专用密码。

[邮箱设置与使用说明](raycast/README.md) · [后台行为与构建说明](native/README.md)

## 从源码构建

需要 Apple Silicon Mac、Apple Command Line Tools、Node.js/npm 和 Raycast。

```sh
git clone --branch inboxcode --single-branch https://github.com/Raysance/toolbox.git
cd toolbox
python3 native/scripts/signing.py setup
bash scripts/build.sh
```

产物：`dist/InboxCode.app`、`dist/InboxCode.rayext`。构建只生成安装包，不安装、不登录邮箱。

首次运行 `signing.py setup` 会在本机默认钥匙串保存一套固定的本地签名证书和私钥。之后构建复用它，重复运行 setup 也不会更换身份。签名配置保存在 `~/Library/Application Support/InboxCode/Signing/identity.json`，里面只有证书指纹与钥匙串位置；私钥不进入源码或安装包。请保留该钥匙串与签名配置，身份丢失时构建会报错，不会退回临时签名。

使用一个原生后台程序，无额外凭据助手。切换签名或更新程序后，macOS 可能要求重新授权 InboxCode 的单条凭据记录；点「始终允许」可保存当前版本的许可。固定本地证书不会绕过 macOS 对更新后程序文件的权限检查，也不等同于 Apple Developer ID 或公证。如使用自己的开发者证书，可设置 `INBOXCODE_SIGNING_IDENTITY` 为其完整 SHA-1 指纹。

```sh
bash native/scripts/test.sh
cd raycast
npm ci
npm test
npm run typecheck
```

## 名称与数据兼容

显示名称改为 InboxCode；内部扩展 ID `mailcode`、应用 ID `local.mailcode.app`、钥匙串服务与原配置路径保持稳定，升级可继续使用既有邮箱。新安装不会包含任何账号配置。示例地址均为虚构。

所有邮箱密码合并存于 macOS 钥匙串中名为 InboxCode 的单条加密记录。旧条目仅在成功迁移并核验后删除。新邮件正文在本地识别，源码和安装包不包含用户邮件、验证码记录或凭据。

查询结果与进度保存在本机 `~/Library/Application Support/MailCode/code-cache.json`，权限 600。每个账号仅保留最新一条验证码，邮件到达 24 小时后清除；没有找到验证码的结果和已处理邮件编号也会保存。再次打开先显示缓存，后台监听更新新增邮件，不反复读取旧邮件正文；完整正文不落盘。账号配置与监听检查点仍在同目录的 `settings.json`。

链接与验证码共用这一缓存，每个账号显示最新一条匹配结果。首次升级到链接识别版，会一次性重查最近最多 30 封邮件以补全旧版漏掉的链接；旧结果在查询期间保留，完成后继续按新增邮件更新。

默认直连。Raycast → Settings → Extensions → InboxCode 可选 Direct、System Settings、SOCKS5 Proxy 或 HTTP Proxy，并填写代理地址和端口；也可以从 Manage Accounts → Connection 打开。设置在下次打开命令时应用并保存给后台。自定义代理需要 macOS 14 及以上，不支持需要用户名/密码的代理。明确选择代理后，失败不会自动回退直连。系统 VPN/TUN 仍由 macOS 的路由控制。

[返回 Toolbox](https://github.com/Raysance/toolbox)
