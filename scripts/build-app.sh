#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
SDK_PATH="${FOLDERBRIDGE_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_ARGS=(--sdk "$SDK_PATH" -c release --arch arm64 --scratch-path "${FOLDERBRIDGE_BUILD_DIR:-$ROOT_DIR/.build}" "$@")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP_DIR="$ROOT_DIR/outputs/FolderBridge.app"
CONTENTS="$APP_DIR/Contents"
LAUNCHER_DIR="$CONTENTS/Library/LoginItems/BaiduDriveSyncLauncher.app"
LAUNCHER_CONTENTS="$LAUNCHER_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/bin" "$CONTENTS/Resources/baidu-drive/scripts" "$LAUNCHER_CONTENTS/MacOS"
cp "$BIN_DIR/BaiduDriveSync" "$CONTENTS/MacOS/BaiduDriveSync"
cp "$BIN_DIR/BaiduDriveSyncLauncher" "$LAUNCHER_CONTENTS/MacOS/BaiduDriveSyncLauncher"
cp "$ROOT_DIR/Resources/Launcher-Info.plist" "$LAUNCHER_CONTENTS/Info.plist"
# Optional, separately obtained backend. No third-party executable or login token is committed.
if [ -n "${BDPAN_BIN:-}" ]; then
    test -x "$BDPAN_BIN"
    cp "$BDPAN_BIN" "$CONTENTS/Resources/bin/bdpan"
fi
if [ -n "${BDPAN_LOGIN_SCRIPT:-}" ]; then
    test -f "$BDPAN_LOGIN_SCRIPT"
    cp "$BDPAN_LOGIN_SCRIPT" "$CONTENTS/Resources/baidu-drive/scripts/login.sh"
    chmod +x "$CONTENTS/Resources/baidu-drive/scripts/login.sh"
fi
chmod +x "$CONTENTS/MacOS/BaiduDriveSync"
chmod +x "$LAUNCHER_CONTENTS/MacOS/BaiduDriveSyncLauncher"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/folderbridge_engine.py" "$CONTENTS/Resources/folderbridge_engine.py"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
codesign --force --sign - "$LAUNCHER_DIR"
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
