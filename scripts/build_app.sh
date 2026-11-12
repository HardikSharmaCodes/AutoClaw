#!/bin/bash
# Builds "build/Claude Servant.app" (ad-hoc signed menu bar app).
set -euo pipefail
cd "$(dirname "$0")/.."
# Universal binary needs full Xcode; fall back to a native build with only the command line tools.
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
  BIN=.build/apple/Products/Release/ClaudeServant
else
  swift build -c release
  BIN=.build/release/ClaudeServant
fi
APP="build/Claude Servant.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeServant"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
