# Toolbox

Raysance 的本地应用与效率工具。每个工具使用独立分支，`main` 提供统一目录和迁移档案。

| 工具 | 分支 | 用途 |
| --- | --- | --- |
| [InboxCode](https://github.com/Raysance/toolbox/tree/inboxcode) | `inboxcode` | 邮箱验证码提取、后台自动复制、Raycast 管理；原名 CodeDrop |
| [AuthCode](https://github.com/Raysance/toolbox/tree/authcode) | `authcode` | 离线 TOTP 动态码、密钥管理与导入导出；原名 2FA |
| [FolderBridge](https://github.com/Raysance/toolbox/tree/folderbridge) | `folderbridge` | 本机、SSH、百度网盘文件同步 |
| [Codex Companion](https://github.com/Raysance/toolbox/tree/codex-companion) | `codex-companion` | 本地 Codex 用量、配额与输入分析 |
| [RayNote](https://github.com/Raysance/toolbox/tree/raynote) | `raynote` | 本地原生笔记 |
| [PagePilot](https://github.com/Raysance/toolbox/tree/pagepilot) | `pagepilot` | 浏览器标签分组和自然语言搜索 |
| [EdgeSwipe](https://github.com/Raysance/toolbox/tree/edgeswipe) | `edgeswipe` | macOS 触控板边缘与角落手势快捷操作 |
| [Microsoft Authenticator TOTP Export](https://github.com/Raysance/toolbox/tree/microsoft-authenticator-totp-export) | `microsoft-authenticator-totp-export` | 从微软 Authenticator 云备份导出 TOTP 密钥的 Python SDK |

## 获取工具

选择上表分支阅读其说明，或只克隆一个工具：

```sh
git clone --branch inboxcode --single-branch https://github.com/Raysance/toolbox.git InboxCode
```

已构建的安装包见 [Releases](https://github.com/Raysance/toolbox/releases)。发布标签以工具名区分，如 `inboxcode/v0.3.1` 和 `raynote/v0.3.1`。请按工具名称选择发布，勿把仓库的全局 latest 当作某个工具的最新版本。

## 历史迁移

Codex Companion、RayNote、PagePilot、EdgeSwipe、Microsoft Authenticator TOTP Export 的 Git 历史保留原提交对象、作者和提交时间。工具分支直接接续原 `main`，没有压成单次源码提交；原标签添加工具名前缀。InboxCode、AuthCode 和 FolderBridge 此前没有独立 Git 提交历史，以本次整理的源码作为首个版本。

- [迁移说明与提交映射](MIGRATION.md)
- [原 GitHub 元数据与 PR 档案](history/)
- 旧版 Releases 的说明和附件随工具名前缀迁入本仓库。
- Issues/PR 的讨论和审核记录以静态档案保存，不会重建为新的讨论或保持原编号关系。
- GitHub 的 Star、Fork、订阅关系和旧 URL 不属于 Git 历史，不能通过迁移提交保留。

每个工具的使用条件与许可证见各自分支；保留已有的第三方归属和许可说明。仓库不包含用户邮箱、TOTP 账号、API Key、同步规则或个人文档。
