#!/bin/bash
# Builds "build/Claude Servant.app" (ad-hoc signed menu bar app).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Claude Servant.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeServant "$APP/Contents/MacOS/ClaudeServant"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
