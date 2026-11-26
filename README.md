# FolderBridge

原生 macOS 文件同步工具，可连接本机文件夹、SSH 服务器和百度网盘。支持按规则定时同步、仅上传或双向同步、冲突确认和恢复快照。

这是已使用版本的源码整理。仓库不包含同步规则、SSH 私钥、网盘凭据、文件账本、用户文件或第三方 `bdpan` 可执行程序。

## 构建

需要 Apple Silicon Mac、macOS 15+ 和 Apple Command Line Tools。同步引擎使用 `/usr/bin/python3`，SSH 端需要 Python 3。

```sh
git clone --branch folderbridge --single-branch https://github.com/Raysance/toolbox.git
cd toolbox
bash scripts/build-app.sh
```

产物为 `outputs/FolderBridge.app`。可通过 `FOLDERBRIDGE_SDK_PATH`、`FOLDERBRIDGE_BUILD_DIR` 覆盖 SDK 和中间构建目录。此脚本只构建，不会安装应用或启动同步。

## 百度网盘后端

本机文件夹与 SSH 同步不需要 `bdpan`。百度网盘功能需要另外取得并安装 `baidu-drive` 提供的 `bdpan` CLI 和登录脚本。运行时会查找 `~/.local/bin/bdpan`、`/opt/homebrew/bin/bdpan` 和 `/usr/local/bin/bdpan`；登录脚本可放在该工具原有的 Codex/Agents skill 目录中。

也可以在构建时显式指定已有文件：

```sh
BDPAN_BIN=/path/to/bdpan \
BDPAN_LOGIN_SCRIPT=/path/to/login.sh \
bash scripts/build-app.sh
```

这些第三方文件不随本源码仓库分发，使用和再分发须遵循其原有条款。登录后再添加同步规则；仓库没有预置账号或远端地址。

## 使用

打开应用，添加本机、SSH 或百度网盘位置，选择两个位置建立同步规则。按需设置上传方向、间隔和网络限制；发生冲突时在界面中确认。首次同步前请检查选中的目录与方向。

同步可能写入文件；双向同步还会处理删除和冲突。恢复快照和上传历史不等同于独立备份。

源文件中的 `BaiduDriveSync` 是内部可执行文件和历史标识，保持不变以兼容现有本机配置。项目总目录见 [Toolbox](https://github.com/Raysance/toolbox)。
