# InboxCode · Raycast

后台收到邮箱验证码后自动复制。打开 Raycast 的「验证码」，查看各邮箱最新一条，显示来源服务、验证码、邮箱和接收时间；按回车再次复制。

## 安装

双击 `InboxCode.rayext` 导入 Raycast。预编译包面向 Apple Silicon，包含约 2.5 MB 的本地收信助手，无需另外安装 Node、Python 或单独启动应用。

首次运行「管理邮箱」→「添加邮箱」，输入完整邮箱地址，自动识别 QQ、Gmail 和普通 SJTU 邮箱。默认只需填写邮箱地址和对应密码；服务器、993 端口和 INBOX 已自动配置，仍可在「更多设置」修改。

| 邮箱 | 自动服务器 | 密码栏填写 |
| --- | --- | --- |
| QQ / Foxmail | `imap.qq.com` | QQ 邮箱 16 位授权码 |
| Gmail | `imap.gmail.com` | Google 16 位应用专用密码 |
| `@sjtu.edu.cn` | `mail.sjtu.edu.cn` | jAccount 密码 |

QQ：网页版邮箱右上角头像 → 设置 → 账号与安全 → 安全设置 → 开启服务 → 生成授权码。[QQ 官方说明](https://help.mail.qq.com/detail/106/985)

Gmail：先开启 Google 两步验证，再到[应用专用密码](https://myaccount.google.com/apppasswords)创建名为 InboxCode 的密码。账号若不提供该选项，当前版本无法使用 Google 一键授权，需要后续 OAuth 支持。[Google 官方说明](https://support.google.com/accounts/answer/185833?hl=zh-Hans)

SJTU：普通 `@sjtu.edu.cn` 按学校说明使用 jAccount 密码；此预设不适用于 `@365.sjtu.edu.cn` 或校友邮箱。[交大官方说明](https://net.sjtu.edu.cn/info/1191/2694.htm)

输入框会自动切换为「QQ 授权码」「Google 应用密码」或「jAccount 密码」。对应帮助入口在 ⌘K 操作菜单中。

## 日常使用

- **验证码**：一行一个邮箱，来源服务 + 验证码；回车复制，⌘R 刷新，⌘N 添加邮箱。
- **管理邮箱**：增删账号，切换自动复制、弹窗提醒和开机启动，也可暂停监听或退出后台。
- 关闭 Raycast 面板后，后台仍监听新邮件并自动复制。不开网页邮箱，也无需点开邮件。
- 没有菜单栏图标或独立设置窗口。列表使用 Raycast 原生外观；验证码提醒显示服务名称、完整收件邮箱与验证码，不显示 ⌘V 提示。

首次查询从每个邮箱最近 30 封邮件中寻找最新验证码。超过 10 分钟标记「较早」，仍可手动复制；后台自动复制只处理最近 10 分钟的新邮件。历史查询不会触发自动复制。首次配置监听跳过历史邮件。

网络优先遵循系统代理；8 秒超时或加密连接失败后，自动优先直连重试（12 秒）。保留 TLS 证书与域名验证，绑定总时限 60 秒。系统代理不可用时可能直接连接邮箱服务器；这不是强制代理模式。

## 数据

邮件直接从 IMAP 服务器进入本机，密码保存在 macOS 钥匙串，不写入 Raycast 表单草稿、命令参数或配置文件。验证码仅保留在后台进程内存；本机连接使用权限为 600 的 Unix socket，不开放网络监听端口。

复制由本地助手完成，标记为敏感内容，默认 90 秒后仅清除仍属于它的剪贴板内容。锁屏暂停并清除验证码；解锁恢复。未将邮件标记为已读。

配置位置为 `~/Library/Application Support/MailCode/settings.json`，不含密码。后台可从 Raycast「管理邮箱」→「退出后台」退出，再次打开命令会重新启动；移除账号会删除其钥匙串授权码。

## 限制与验证

支持通用 IMAP 隐式 TLS、授权码/应用专用密码或服务商允许的邮箱密码登录，暂不包含 Gmail / Microsoft OAuth。仅允许 OAuth 的账号不能接入。验证码启发式识别可能漏检或误判，来源名称综合标题【品牌】/[Brand] 标签、正文验证码附近的品牌词、发件人域名与名称提取，过滤通用标签，未知时回退到发件人；不代表已验证的服务身份。

本地构建、ad-hoc 签名，未进行 Apple Developer ID 公证。原生助手目标 macOS 13+；验证码提醒使用系统半透明材质的紧凑横条。Raycast 自身的系统要求以其当前版本为准。

已通过 30 项连接回退/绑定时限/IMAP/MIME/验证码/来源识别测试及 5 项邮箱预设测试、TypeScript 类型检查、Raycast 构建与安装包校验；已实测 TypeScript 客户端自动启动收信助手、Unix socket 查询、错误传递、并发请求、独立测试剪贴板及钥匙串读写。已用实际收信实现验证 QQ、Gmail、SJTU 三家服务器的 TLS 连接、IMAP 欢迎响应与 CAPABILITY。当前本机代理的 Gmail TLS 连接失败，回退路径可连通；实际账号需在安装后自行连接验证。

## 源码构建

相邻的 `native` 文件夹为原生助手源码。先用 `scripts/build-app.sh` 构建，将生成的 app 复制到本项目的 `assets/MailCode.app`，然后运行：

```sh
npm ci
npm test
npm run typecheck
npm run build
npm run bundle -- --output ../InboxCode.rayext
```

本地开发导入使用 `npm run dev`。无需发布到商店。扩展包含「验证码」和「管理邮箱」两个命令；不会使用 Raycast 定时轮询来模拟实时收信，实时监听由原生 IMAP IDLE 实现。

参考：[Raycast CLI](https://developers.raycast.com/information/developer-tools/cli)、[Raycast 列表](https://developers.raycast.com/api-reference/user-interface/list)、[Raycast 表单](https://developers.raycast.com/api-reference/user-interface/form)、[Apple Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)。
