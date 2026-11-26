# InboxCode · Raycast

后台收到邮箱验证码后自动复制。打开 Raycast 的「Verification Codes」，查看各邮箱最新一条，显示来源服务、验证码、邮箱和接收时间；按回车再次复制。

## 安装

双击 `InboxCode.rayext` 导入 Raycast。预编译包面向 Apple Silicon，包含约 2.5 MB 的本地收信助手，无需另外安装 Node、Python 或单独启动应用。

首次运行「Manage Accounts」→「Add Account」，输入完整邮箱地址，自动识别 QQ、Gmail 和普通 SJTU 邮箱。默认只需填写邮箱地址和对应密码；服务器、993 端口和 INBOX 已自动配置，仍可在「Advanced」修改。

| 邮箱 | 自动服务器 | 密码栏填写 |
| --- | --- | --- |
| QQ / Foxmail | `imap.qq.com` | QQ 邮箱 16 位授权码 |
| Gmail | `imap.gmail.com` | Google 16 位应用专用密码 |
| `@sjtu.edu.cn` | `mail.sjtu.edu.cn` | jAccount 密码 |

QQ：网页版邮箱右上角头像 → 设置 → 账号与安全 → 安全设置 → 开启服务 → 生成授权码。[QQ 官方说明](https://help.mail.qq.com/detail/106/985)

Gmail：先开启 Google 两步验证，再到[应用专用密码](https://myaccount.google.com/apppasswords)创建名为 InboxCode 的密码。账号若不提供该选项，当前版本无法使用 Google 一键授权，需要后续 OAuth 支持。[Google 官方说明](https://support.google.com/accounts/answer/185833?hl=zh-Hans)

SJTU：普通 `@sjtu.edu.cn` 按学校说明使用 jAccount 密码；此预设不适用于 `@365.sjtu.edu.cn` 或校友邮箱。[交大官方说明](https://net.sjtu.edu.cn/info/1191/2694.htm)

输入框会自动切换为「QQ App Password」「Google App Password」或「jAccount Password」。对应帮助入口在 ⌘K 操作菜单中。

## 日常使用

- **验证码**：一行一个邮箱，来源服务 + 验证码；回车复制，⌘R 刷新，⌘N 添加邮箱。
- **验证链接**：密码重置、邮箱验证及登录邮件显示链接图标、来源服务和目标域名；回车或 `Copy Link` 复制完整地址。桌面提醒也可点击 `Copy Link`，不会自动打开网址或在收到时覆盖剪贴板。支持正文中的 URL 和 HTML 按钮。
- **管理邮箱**：增删账号，切换自动复制、弹窗提醒和开机启动，也可暂停监听或退出后台。
- 关闭 Raycast 面板后，后台仍监听新邮件并自动复制。不开网页邮箱，也无需点开邮件。
- 没有菜单栏图标或独立设置窗口。列表使用 Raycast 原生外观；验证码提醒显示服务名称、完整收件邮箱与验证码，不显示 ⌘V 提示。

首次查询从每个邮箱最近 30 封邮件中寻找最新验证码。超过 10 分钟标记「Older」，仍可手动复制；后台自动复制只处理最近 10 分钟的新邮件。历史查询不会触发自动复制。首次配置监听跳过历史邮件。

结果和进度会保存，包括「No Code Found」。再次打开立即显示本地缓存，在线监听会更新新邮件；⌘R 只核对状态并读取新增邮件，超时后也不会重新读取已处理的正文。每个邮箱独立显示 Connecting、Checking、Searching 或查询结果，不再因为其他邮箱未完成而一直显示 Searching。缓存的验证码在邮件到达 24 小时后清除，已扫描进度继续保留。

验证码和验证链接共用缓存，每个账号显示最新一条匹配邮件。链接同样在邮件到达 24 小时后从本地清除，实际可用时间由服务商决定。首次升级到链接识别版需一次性重新检查最近最多 30 封邮件，补全旧版漏掉的链接；完成后不再重复读取。

默认直连。在 Raycast → Settings → Extensions → InboxCode 中选择 Direct、System Settings、SOCKS5 Proxy 或 HTTP Proxy，并填写代理主机和端口。也可从 Manage Accounts → Connection 打开设置。设置会在下次打开命令时传给后台并保存；自定义代理需要 macOS 14+，暂不支持代理账号密码。连接失败不会擅自切换到直连；VPN/TUN 仍由系统路由控制。

## 数据

邮件直接从 IMAP 服务器进入本机，所有邮箱凭据合并保存在 macOS 钥匙串名为 InboxCode 的单条加密记录，不写入 Raycast 表单草稿、命令参数或配置文件。每个账号最新验证码和查询进度保存在 `~/Library/Application Support/MailCode/code-cache.json`，权限为 600，不保存完整邮件正文。本机连接使用权限为 600 的 Unix socket，不开放网络监听端口。

复制由本地助手完成，标记为敏感内容，默认 90 秒后仅清除仍属于它的剪贴板内容。锁屏暂停并清除内存中的验证码及仍属于它的剪贴板内容；解锁从缓存恢复。未将邮件标记为已读。

配置位置为 `~/Library/Application Support/MailCode/settings.json`，不含密码。后台可从 Raycast「Manage Accounts」→「Quit Background Helper」退出，再次打开命令会重新启动；移除账号会删除其钥匙串授权码及缓存。

## 限制与验证

支持通用 IMAP 隐式 TLS、授权码/应用专用密码或服务商允许的邮箱密码登录，暂不包含 Gmail / Microsoft OAuth。仅允许 OAuth 的账号不能接入。验证码启发式识别可能漏检或误判，来源名称综合标题【品牌】/[Brand] 标签、正文验证码附近的品牌词、发件人域名与名称提取，过滤通用标签，未知时回退到发件人；不代表已验证的服务身份。

本地构建、固定本地证书签名，未进行 Apple Developer ID 公证。原生助手目标 macOS 13+；验证码提醒使用系统半透明材质的紧凑横条。Raycast 自身的系统要求以其当前版本为准。

测试覆盖 IMAP、IDLE、MIME、验证码提取、网络模式和邮箱预设，并执行 TypeScript 类型检查、原生应用自检与 Raycast 构建。当前本机实测 QQ、Gmail、SJTU 的直连 TLS 与 IMAP 欢迎响应均成功，完整登录仍依赖账号凭据与邮箱服务商设置。

## 源码构建

相邻的 `native` 文件夹为原生助手源码。先用 `scripts/build-app.sh` 构建，将生成的 app 复制到本项目的 `assets/MailCode.app`，然后运行：

```sh
npm ci
npm test
npm run typecheck
npm run build
npm run bundle -- --output ../InboxCode.rayext
```

本地开发导入使用 `npm run dev`。无需发布到商店。扩展包含「Verification Codes」和「Manage Accounts」两个命令；不会使用 Raycast 定时轮询来模拟实时收信，实时监听由原生 IMAP IDLE 实现。

参考：[Raycast CLI](https://developers.raycast.com/information/developer-tools/cli)、[Raycast 列表](https://developers.raycast.com/api-reference/user-interface/list)、[Raycast 表单](https://developers.raycast.com/api-reference/user-interface/form)、[Apple Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)。
