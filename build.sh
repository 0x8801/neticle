#!/bin/zsh
# Build Neticle.app (menu bar network meter).
set -euo pipefail
cd "$(dirname "$0")"

APP=Neticle.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo "• compiling…"
swiftc -O -o "$APP/Contents/MacOS/Neticle" Sources/Core.swift Sources/main.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "• built $PWD/$APP"
