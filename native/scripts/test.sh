#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${MAILCODE_BUILD_DIR:-$PROJECT_DIR/.build}"
TOOLCHAIN_BIN="$(dirname "$(xcrun --find swiftc)")"
PLUGIN="$TOOLCHAIN_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
FLAGS=()
# Some standalone CLT releases omit this plugin from swiftbuild's resolved list.
if [ -f "$PLUGIN" ]; then
    FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi
swift test --disable-xctest --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" "${FLAGS[@]}"
