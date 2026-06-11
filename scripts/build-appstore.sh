#!/bin/zsh
# Builds the Mac App Store variant: universal binary, App Sandbox enabled,
# packaged as an installer .pkg ready for upload with Transporter.
#
# With no signing identities set this produces an UNSIGNED pkg plus an ad-hoc
# sandboxed .app you can run locally to test sandbox behaviour. For a real
# submission (requires Apple Developer Program membership):
#
#   APP_IDENTITY="Apple Distribution: Your Name (TEAMID)" \
#   INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
#   ./scripts/build-appstore.sh
#
# NOTE: under the App Sandbox nettop cannot query per-process network stats,
# so this variant shows interface totals only (the menu says so). Full
# functionality outside the App Store: use Developer ID + notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
APP_IDENTITY="${APP_IDENTITY:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"

mkdir -p build dist
rm -rf dist/appstore && mkdir -p dist/appstore

echo "• compiling universal binary…"
swiftc -O -target arm64-apple-macos12  -o build/Neticle-arm64  Sources/Core.swift Sources/main.swift
swiftc -O -target x86_64-apple-macos12 -o build/Neticle-x86_64 Sources/Core.swift Sources/main.swift
lipo -create -output build/Neticle-universal build/Neticle-arm64 build/Neticle-x86_64

APP="dist/appstore/Neticle.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Neticle-universal "$APP/Contents/MacOS/Neticle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$APP_IDENTITY" ]]; then
    echo "• signing with: $APP_IDENTITY"
    codesign --force --sign "$APP_IDENTITY" \
             --entitlements Resources/Neticle-AppStore.entitlements "$APP"
    PKG="dist/Neticle-$VERSION-appstore.pkg"
    productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
else
    echo "• no APP_IDENTITY set — ad-hoc signing (local sandbox testing only)"
    codesign --force --sign - \
             --entitlements Resources/Neticle-AppStore.entitlements "$APP"
    PKG="dist/Neticle-$VERSION-appstore-unsigned.pkg"
    productbuild --component "$APP" /Applications "$PKG"
fi

codesign -d --entitlements - "$APP" 2>/dev/null | grep -A1 app-sandbox || true
echo "• built $PKG"
