# Neticle

A tiny macOS menu bar app for live system stats: network, CPU, memory, and
disk — each with a top-5 list and quick actions.

- **Menu bar:** whichever stats you pin (network `↓ 12.3 ↑ 0.4 Mbps` by
  default; CPU/RAM/DISK show as percentages). Refreshed every second.
- **Click the item** for the stats popover:
  - **Network** — total ↓/↑ Mbps plus the top 5 processes by traffic.
    While the popover is open a live `nettop` stream refreshes this every 2 s;
    in the background only cheap snapshots run.
  - **CPU** — total usage plus the top 5 processes.
  - **Memory** — used/total plus the top 5 processes by resident size.
  - **Internet** — connection state (online/offline), a latency sparkline
    from tiny TCP-handshake probes, your **public IP, location, and ISP**,
    and an outage log. Deliberately non-invasive: no bandwidth-eating speed
    tests, just a few packets per probe and instant offline detection via
    `NWPathMonitor`.
  - **Disk** — used/total, plus an on-demand scan of your largest home
    folders (the scan never runs at launch — see Permissions below).
  - Hover a process row to **terminate** it (click the ✕ twice to confirm)
    or **view its recent logs** in Console. Hover a folder row to **reveal it
    in Finder** so you can clean things up.
  - The **pin** on each section toggles it into the menu bar title.
- **Preferences** (gear in the popover, or right-click the menu bar item):
  turn sections on/off (off also stops their sampling), tune refresh
  intervals, and enable **launch at login** (macOS 13+).
- Right-click the menu bar item for Preferences/Quit (or use the power
  button in the popover).

No Dock icon (`LSUIElement`). No special permissions needed. Universal
binary (Apple Silicon + Intel), macOS 12+. Idle CPU is ~1%; while the
popover is open the live network stream costs about a core (same class of
burst as Activity Monitor's network tab — it stops when the popover closes).

The network totals come from physical interface byte counters (`en*`,
`pdp_ip*`, `ppp*`; tunnels like `utun` are excluded so VPNs don't
double-count).

## Permissions & privacy

Network, CPU, and memory stats need **no permissions**. The disk folder
scan reads Desktop, Documents, Downloads, and app data — locations macOS
protects — so the first scan triggers the standard permission prompts, one
per category. That's why the scan only runs when you click **Scan largest
folders** in the popover, never at launch. macOS remembers what you allow
(deny something and that folder is simply skipped). To skip the prompts
entirely, grant Neticle **Full Disk Access** in System Settings → Privacy &
Security.

The Internet section makes two kinds of outbound requests, both only while
that section is enabled: connectivity probes (a TCP handshake to
`1.1.1.1:443`, a few packets each) and IP-details lookups against
[ipwho.is](https://ipwho.is) with [ipapi.co](https://ipapi.co) as fallback —
the lookup service necessarily sees your public IP (that's what it answers
with). Nothing else leaves your machine; turn the section off in
Preferences and no requests are made.

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

The app mirrors its full state (rates, all top-5 lists, pinned stats, status
item frame) to `/tmp/neticle-state.json` once a second (path overridable via
`NETICLE_STATE`), so behaviour is verifiable from the CLI. Debug hooks:
`kill -USR1 <pid>` toggles the popover, `kill -USR2 <pid>` toggles the live
network stream headlessly. `NETICLE_SCAN_PATH` points the disk scanner at a
test directory.

## Distribution

See [DISTRIBUTION.md](DISTRIBUTION.md) for packaging GitHub releases
(`scripts/package-release.sh`) and the Mac App Store variant
(`scripts/build-appstore.sh`). The MAS sandbox blocks per-process data
(nettop, ps) and home-folder scanning, so that variant shows totals only —
the app detects this and says so in each section.

## Implementation notes

- **Per-process network is sampled two ways.** Streaming `nettop -d -L 0`
  spins at >100% CPU in its event loop on busy systems, so the background
  path takes one-shot snapshots (`-L 1`, ~0.02 s CPU) every 6 s and diffs the
  cumulative counters in-app — that misses processes shorter than two
  snapshots (nettop enumerates processes at launch). While the popover is
  open, the full stream runs (under a PTY — nettop block-buffers when piped)
  for fresh 2 s windows that catch short-lived processes too.
- Swift folds `"\r\n"` into a *single* `Character`, so the PTY stream parser
  matches both `\n` and the CRLF cluster — `firstIndex(of: "\n")` alone never
  finds CRLF newlines.
- nettop truncates process names to ~15 characters (e.g. “Google Chrome H”).
- When a VPN is active (e.g. Tailscale), the per-process network list shows
  both the app and the tunnel daemon (`IPNExtension`) carrying the same
  bytes — Activity Monitor does the same. The headline Mbps counts physical
  interfaces only, so it stays accurate.
- CPU totals come from `host_processor_info` tick deltas, memory from
  `host_statistics64` (active + wired + compressed), disk from `statfs`, and
  per-process CPU/RSS from one `ps -Aceo` call per 3 s tick.
- Neticle's own footprint — the app and its helper children (the
  popover-open nettop stream, background nettop snapshots, du scans) — is
  excluded from the top-5 lists by pid, so the monitor doesn't list its own
  sampling as a consumer. The headline totals still include everything, and
  an unrelated `nettop`/`du` you run yourself still shows up.
- The popover's SwiftUI hierarchy is created on open and torn down on close:
  a hidden `NSHostingView` re-renders on every published sample, which costs
  real CPU in an app that ticks every second.
- On macOS 26 third-party status item windows are hosted by Control Centre,
  so they don't show up under the app's pid in `CGWindowListCopyWindowInfo` —
  use the state file's `itemFrame` instead.

## License

[MIT](LICENSE)
