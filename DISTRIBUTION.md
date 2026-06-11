# Distributing Neticle

Two channels are supported. The per-process features (top-5 lists, kill,
logs) and the home-folder disk scan need OS queries that the Mac App Store
sandbox denies — so the channels differ in functionality:

| Channel | Totals (net/CPU/RAM/disk) | Top-5 lists & actions | Folder scan | Script |
|---|---|---|---|---|
| GitHub release (direct download) | ✅ | ✅ | ✅ | `scripts/package-release.sh` |
| Mac App Store (sandboxed) | ✅ | ❌ shows a notice | ✅ (metadata reads are allowed) | `scripts/build-appstore.sh` |

Both scripts build a universal (arm64 + x86_64) binary, minimum macOS 12.

## GitHub releases

```sh
./scripts/package-release.sh
# → dist/Neticle-<version>.zip, dist/Neticle-<version>.dmg, dist/checksums.txt
gh release create v<version> dist/Neticle-<version>.zip dist/Neticle-<version>.dmg dist/checksums.txt
```

The artifacts are **ad-hoc signed** (no Developer ID), so downloads are
quarantined by Gatekeeper. Users install by dragging `Neticle.app` to
Applications and then either:

```sh
xattr -dr com.apple.quarantine /Applications/Neticle.app
```

or opening it once, then approving it under
**System Settings → Privacy & Security → "Open Anyway"**.

### Recommended upgrade: Developer ID + notarization

With an Apple Developer Program membership ($99/yr) you can make direct
downloads friction-free while keeping full functionality:

```sh
codesign --force --options runtime --sign "Developer ID Application: NAME (TEAMID)" Neticle.app
ditto -c -k --keepParent Neticle.app Neticle.zip
xcrun notarytool submit Neticle.zip --keychain-profile <profile> --wait
xcrun stapler staple Neticle.app    # then re-zip / build the DMG
```

## Mac App Store

What's already prepared in this repo:

- `Resources/Neticle-AppStore.entitlements` — App Sandbox entitlement (mandatory for MAS).
- `Resources/Info.plist` — bundle id `com.egithinji.neticle`, version,
  category (`public.app-category.utilities`), icon, encryption exemption.
- The app degrades gracefully under the sandbox (nettop/ps produce no
  per-process data): the affected sections show an "unavailable" notice
  instead of an empty list, while totals and the folder scan keep working —
  verified locally by running the sandboxed build.
- `scripts/build-appstore.sh` — builds, signs, and produces the installer pkg.

Submission steps (need an Apple Developer account; none of this can be done
without one):

1. Enroll at developer.apple.com, then in App Store Connect create a macOS app
   record with bundle ID `com.egithinji.neticle`.
2. In Xcode → Settings → Accounts (or developer.apple.com), create the
   certificates: **Apple Distribution** and **Mac Installer Distribution**.
3. Build the signed pkg:
   ```sh
   APP_IDENTITY="Apple Distribution: Your Name (TEAMID)" \
   INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
   ./scripts/build-appstore.sh
   ```
4. Upload `dist/Neticle-<version>-appstore.pkg` with the
   [Transporter](https://apps.apple.com/app/transporter/id1450874784) app.
5. In App Store Connect: add screenshots/description, then submit for review.
   Review notes should mention the app is a menu-bar-only utility
   (`LSUIElement`) with no Dock icon.

Honest assessment: for a network monitor whose headline feature is per-process
usage, the App Store build is a degraded experience. Developer ID +
notarization via GitHub releases is the channel that preserves the full app.

## Versioning

Bump `CFBundleShortVersionString` in `Resources/Info.plist` (and
`CFBundleVersion` for each MAS upload), rebuild, tag `v<version>`, release.
