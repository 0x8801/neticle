#!/bin/zsh
# Builds the GitHub release artifacts: a universal (arm64 + x86_64) ad-hoc
# signed Neticle.app, zipped and wrapped in a drag-to-Applications DMG.
# Output lands in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
echo "• packaging Neticle $VERSION"

mkdir -p build dist
rm -rf dist/release && mkdir -p dist/release

echo "• compiling universal binary…"
swiftc -O -target arm64-apple-macos12  -o build/Neticle-arm64  Sources/*.swift
swiftc -O -target x86_64-apple-macos12 -o build/Neticle-x86_64 Sources/*.swift
lipo -create -output build/Neticle-universal build/Neticle-arm64 build/Neticle-x86_64

APP="dist/release/Neticle.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Neticle-universal "$APP/Contents/MacOS/Neticle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
lipo -info "$APP/Contents/MacOS/Neticle"

echo "• zipping…"
ditto -c -k --keepParent "$APP" "dist/Neticle-$VERSION.zip"

echo "• building DMG…"
STAGING="dist/dmg-staging"
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "dist/Neticle-$VERSION.dmg"
hdiutil create -volname "Neticle $VERSION" -srcfolder "$STAGING" -format UDZO -quiet "dist/Neticle-$VERSION.dmg"
rm -rf "$STAGING"

echo "• checksums:"
(cd dist && shasum -a 256 "Neticle-$VERSION.zip" "Neticle-$VERSION.dmg" | tee checksums.txt)
echo "• done — artifacts in dist/"
