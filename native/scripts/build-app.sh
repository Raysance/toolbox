#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${MAILCODE_BUILD_DIR:-$PROJECT_DIR/.build}"
DESTINATION="${1:-$PROJECT_DIR/dist}"
mkdir -p "$DESTINATION"
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
APP_PATH="$DESTINATION/InboxCode.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/MailCode" "$APP_PATH/Contents/MacOS/MailCode"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MailCode</string>
<key>CFBundleIdentifier</key><string>local.mailcode.app</string>
<key>CFBundleName</key><string>InboxCode</string>
<key>CFBundleDisplayName</key><string>InboxCode</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
ICON_DIR="$BUILD_DIR/MailCode.iconset"
mkdir -p "$ICON_DIR"
swift "$PROJECT_DIR/scripts/make-icon.swift" "$ICON_DIR"
iconutil -c icns "$ICON_DIR" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.mailcode.app "$APP_PATH"
codesign --verify --strict "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
