#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAILCODE_BUILD_DIR="${MAILCODE_BUILD_DIR:-$ROOT/.build/native}" bash "$ROOT/native/scripts/build-app.sh" "$ROOT/dist"
ditto "$ROOT/dist/InboxCode.app" "$ROOT/raycast/assets/MailCode.app"
cd "$ROOT/raycast"
npm ci
npm run bundle -- --output "$ROOT/dist/InboxCode.rayext"
