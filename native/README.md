# InboxCode · MailCode

轻量的 macOS 后台验证码助手，通过 Raycast 管理。邮箱收到新验证码后自动复制，右上角显示 8 秒轻提示，然后直接按 ⌘V 粘贴。无需反复打开网页邮箱。

## 使用

1. 导入相邻的 `InboxCode.rayext`，在 Raycast 打开「管理邮箱」→「添加邮箱」。
2. 填写邮箱地址和对应密码或授权码。QQ、Gmail、普通 SJTU 自动识别；其他邮箱在「更多设置」填写 IMAP 服务器。默认 TLS 993、`INBOX`。
3. 连接成功后关闭 Raycast，后台继续监听。没有菜单栏图标和独立设置窗口。
4. 收到新验证码后自动复制，提醒显示来源服务、收件邮箱和验证码。Raycast「验证码」可查看和补复制；「管理邮箱」可暂停监听或退出后台。

首次设置可能需要去邮箱服务商开启 IMAP 和生成授权码。完成后无需日常打开网页邮箱。工具不会代你申请验证码，也不会自动向网站提交验证码。

## 行为

- 多账号、通用 IMAP，隐式 TLS 加密及系统证书校验。支持 LOGIN / AUTHENTICATE PLAIN，凭据仅在 TLS 内发送。
- 网络先使用系统代理设置，8 秒未能完成加密连接或连接失败后，再优先直连重试（12 秒）。所有路径均验证 TLS 证书和服务器域名，不降级为明文。绑定连接及登录总时限为 60 秒；此回退意味着系统代理不可用时连接可能直接访问邮箱服务器。
- 优先使用 IMAP IDLE 推送，约 25 分钟续订；服务器不支持时每 20 秒检查。网络断开后以 5～300 秒退避重连，登录失败每 300 秒重试。
- `EXAMINE` 与 `BODY.PEEK` 只读访问，不标记已读、不移动、不删除邮件。
- 首次连接及 UIDVALIDITY 改变时以当前 UIDNEXT 为起点，跳过历史邮件。重连后只接受服务器到达时间在最近 10 分钟以内的邮件，单次最多处理最新 100 封。
- 支持常见中文、英文上下文，4～8 位数字、6～10 位数字字母组合、分组数字；解码常见 UTF-8/GB18030、Base64、Quoted-Printable、multipart 和 HTML 文本。
- 每封最多读取前 256 KiB，不处理附件和图片验证码；置信度不足或多个相近候选时不复制。纯字母验证码暂不识别。启发式提取仍可能漏识别或误识别，建议先用常用服务试收。
- 最近 8 条验证码仅保留在内存，10 分钟后清除。最新到达的验证码覆盖前一个；Raycast 可查询每个账号最新的验证码邮件并手动复制。
- 自动复制默认开启；可单独关闭弹窗或自动复制。默认 90 秒清除本工具复制的内容，通过剪贴板 changeCount 判断，不删除你后来复制的内容。
- 收到锁屏/用户切换通知后暂停监听、隐藏弹窗并清除本工具仍持有的剪贴板内容；解锁恢复。睡眠暂停，唤醒重连。
- 可以设置登录 Mac 自动启动。在 Raycast「管理邮箱」中开启。

## 界面

Raycast 使用原生列表与表单。新验证码的可选轻提示显示服务名称、完整收件邮箱、验证码，不附加“验证码”文字、复制状态图标或快捷键提示。名称综合标题的【品牌】或 [Brand] 标签、品牌关键词、发件人域名和名称识别；通用标签与验证码本身会过滤，无法判断时显示发件人或域名。这是显示名称推断，不是发件人身份认证。使用 340 × 62 的紧凑横条与系统半透明材质，服务和邮箱在左侧，验证码在右侧。

## 当前边界

这是本地构建的 v0.3.1，使用 ad-hoc 签名，未进行 Apple Developer ID 签名和公证。本次预编译包面向 Apple Silicon，最低目标 macOS 13。未在其他 Mac 或旧版系统做实机验证。

当前只支持允许 IMAP 授权码/应用专用密码登录的账号。**不包含 Gmail / Microsoft OAuth 网页授权**，仅允许 OAuth 的账号不能使用此版本。邮箱服务器必须支持隐式 TLS，不支持明文连接和 STARTTLS-only 端口。具体服务器地址及 IMAP 开启方式以服务商说明为准。

邮件和凭据直接在本机与邮箱服务器之间传输，无中转服务、分析埋点或云端验证码存储。macOS 通用剪贴板可能按系统设置同步到你的其他 Apple 设备；剪贴板历史工具是否遵守敏感内容标记由其自身决定。

## 本地数据与卸载

- 授权码存于登录钥匙串，服务名 `local.mailcode.credentials`，每个账号以独立 UUID 索引；配置文件不含密码。
- 服务器、账号、偏好与 UID 检查点存于 `~/Library/Application Support/MailCode/settings.json`，文件权限 600。
- 移除邮箱会删除该账号的钥匙串凭据。卸载前先移除账号并关闭开机启动，然后退出并删除应用；需要彻底清理时再删除上述配置目录。

## 构建与验证

原生 Swift + SwiftUI + AppKit + Network.framework + Security.framework，无第三方运行依赖。需要包含 macOS 26 SDK 的 Swift 6.2 及以上工具链或 Xcode 26 及以上；应用目标 macOS 13。

```sh
bash scripts/test.sh
bash scripts/build-app.sh
"dist/InboxCode.app/Contents/MacOS/MailCode" --self-test
```

`--self-test` 使用独立测试剪贴板，不修改日常剪贴板。`--render-preview /absolute/path/preview.png` 可离屏渲染演示界面，不接入真实邮箱。

协议测试使用脚本化 IMAP 传输，覆盖认证、只读 FETCH、IDLE/DONE、服务端拒绝、逐字节分片、literal 边界、数据上限、UID 过滤。实际邮箱登录和服务商兼容性需要使用用户自己的账号完成验证。

源码入口：`Sources/MailCodeCore` 为协议、MIME 和识别逻辑；`Sources/MailCodeApp` 为界面、钥匙串、监听管理和剪贴板；`scripts` 为打包脚本。

参考：[IMAP RFC 9051](https://www.rfc-editor.org/rfc/rfc9051.html)、[IDLE RFC 2177](https://www.rfc-editor.org/rfc/rfc2177)、[Apple Network](https://developer.apple.com/documentation/network/nwconnection)、[非激活面板](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)、[系统剪贴板](https://developer.apple.com/documentation/appkit/nspasteboard)。
