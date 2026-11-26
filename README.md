# InboxCode

原名 CodeDrop。轻量 macOS 邮箱验证码助手：后台通过 IMAP 监听新邮件，提取验证码并自动复制；Raycast 查看各账号最新代码、管理邮箱，桌面可显示紧凑提醒。

支持通用 IMAP，内置 QQ、Gmail、普通 SJTU 配置。使用 TLS 和系统证书验证，当前程序以只读方式访问收件箱。无需日常打开网页邮箱。

## 安装与使用

安装包位于本仓库的 [Releases](https://github.com/Raysance/toolbox/releases)，选择 InboxCode 发布中的 `.rayext` 文件导入 Raycast。打开「管理邮箱」添加账号，填写对应的授权码或应用专用密码。

[邮箱设置与使用说明](raycast/README.md) · [后台行为与构建说明](native/README.md)

## 从源码构建

需要 Apple Silicon Mac、Apple Command Line Tools、Node.js/npm 和 Raycast。

```sh
git clone --branch inboxcode --single-branch https://github.com/Raysance/toolbox.git
cd toolbox
bash scripts/build.sh
```

产物：`dist/InboxCode.app`、`dist/InboxCode.rayext`。构建只生成安装包，不安装、不登录邮箱。

```sh
bash native/scripts/test.sh
cd raycast
npm ci
npm test
npm run typecheck
```

## 名称与数据兼容

显示名称改为 InboxCode；内部扩展 ID `mailcode`、应用 ID `local.mailcode.app`、钥匙串服务与原配置路径保持稳定，升级可继续使用既有邮箱。新安装不会包含任何账号配置。示例地址均为虚构。

密码存于 macOS 钥匙串。新邮件正文在本地识别，源码和安装包不包含用户邮件、验证码记录或凭据。系统代理连接失败后会优先直连重试，因此它不是强制代理模式。

[返回 Toolbox](https://github.com/Raysance/toolbox)
