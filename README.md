# Neticle

A tiny macOS menu bar app that shows live network throughput and, on click,
the top 5 processes using the network.

- **Menu bar:** `↓ 12.3 ↑ 0.4 Mbps` — download/upload in megabits per second,
  refreshed every second from the physical interface byte counters
  (`en*`, `pdp_ip*`, `ppp*`; tunnels like `utun` are excluded so VPNs don't
  double-count).
- **Click the item:** total rates plus the top 5 processes by network usage
  over the last 2 seconds, sampled from a streaming `nettop` child process.
  Quit from the same menu (⌘Q while open).

No Dock icon (`LSUIElement`). No special permissions needed. Universal
binary (Apple Silicon + Intel), macOS 12+.

## Install (from a GitHub release)

1. Download `Neticle-<version>.dmg` (or the zip) from
   [Releases](../../releases), open it, drag **Neticle** to Applications.
2. Releases are ad-hoc signed, not notarized, so Gatekeeper quarantines the
   download. Clear it with:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Neticle.app
   ```
   (or open the app once, then approve it under **System Settings →
   Privacy & Security → "Open Anyway"**).
3. Launch Neticle — the meter appears at the right of your menu bar.

To start it automatically at login: System Settings → General → Login Items →
"Open at Login" → **+** → select `Neticle.app`.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh          # compiles Sources/ into Neticle.app and ad-hoc signs it
open Neticle.app    # starts it; the meter appears in the menu bar
```

## Tests & QA

```sh
swiftc -o build/neticle-tests Sources/Core.swift Tests/main.swift && ./build/neticle-tests
./qa/smoke.sh            # restart the app, verify process + published state
./qa/traffic_test2.sh    # ~10 s real download, per-second meter readings
```

The app mirrors its full state (title, rates, menu rows, status item frame)
to `/tmp/neticle-state.json` once a second (path overridable via the
`NETICLE_STATE` env var), so its behaviour is verifiable from the CLI:
`itemVisible` / `itemFrame` are AppKit's own report of the menu bar slot the
item occupies.

## Distribution

See [DISTRIBUTION.md](DISTRIBUTION.md) for packaging GitHub releases
(`scripts/package-release.sh`) and the Mac App Store variant
(`scripts/build-appstore.sh`), including the App Sandbox limitation: MAS
builds can't run `nettop`, so they show interface totals only.

## Implementation notes

- `nettop -P -d -x -J bytes_in,bytes_out -L 0` is run under a PTY
  (`script -q /dev/null …`) because nettop block-buffers when piped, which
  would delay samples by many seconds. The parser therefore handles `\r\n`
  endings — and beware: Swift folds `"\r\n"` into a *single* `Character`,
  so `firstIndex(of: "\n")` alone never finds CRLF newlines.
- nettop truncates process names to ~15 characters (e.g. “Google Chrome H”).
- When a VPN is active (e.g. Tailscale), the per-process list shows both the
  app and the tunnel daemon (`IPNExtension`) carrying the same bytes —
  Activity Monitor does the same. The headline Mbps counts physical
  interfaces only, so it stays accurate.
- On macOS 26 third-party status item windows are hosted by Control Centre,
  so they don't show up under the app's pid in `CGWindowListCopyWindowInfo` —
  use the state file's `itemFrame` instead.

## License

[MIT](LICENSE)
