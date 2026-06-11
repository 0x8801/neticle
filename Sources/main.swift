import AppKit

// Neticle — menu bar network throughput meter.
// Shows live ↓/↑ Mbps in the status bar; the menu lists the top 5 processes
// by current network usage (sampled from `nettop`). Mirrors its state to
// /tmp/neticle-state.json so the behaviour can be verified from the CLI.

// Overridable because the sandboxed (App Store) variant cannot write /tmp;
// QA scripts point this at a container path instead.
let statePath = ProcessInfo.processInfo.environment["NETICLE_STATE"] ?? "/tmp/neticle-state.json"

// MARK: - Total throughput via per-interface byte counters

final class NetworkRateSampler {
    struct Rate {
        let downBytesPerSec: Double
        let upBytesPerSec: Double
    }

    private var previous: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var previousAt: Date?

    func sample() -> Rate? {
        let now = Date()
        let current = Self.readCounters()
        let last = previous
        let lastAt = previousAt
        previous = current
        previousAt = now
        guard let lastAt, !last.isEmpty else { return nil }
        let dt = now.timeIntervalSince(lastAt)
        guard dt > 0.2 else { return nil }
        var dRx: UInt64 = 0
        var dTx: UInt64 = 0
        for (name, cur) in current {
            guard let prev = last[name] else { continue }
            dRx &+= UInt64(cur.rx &- prev.rx)   // &- absorbs 32-bit counter wrap
            dTx &+= UInt64(cur.tx &- prev.tx)
        }
        return Rate(downBytesPerSec: Double(dRx) / dt, upBytesPerSec: Double(dTx) / dt)
    }

    // en* = Wi-Fi/Ethernet, pdp_ip* = cellular, ppp* = legacy VPN/dial.
    // utun/awdl/llw/lo are skipped so VPN tunnels don't double-count traffic.
    private static func isCounted(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("ppp")
    }

    private static func readCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return result }
        defer { freeifaddrs(addrs) }
        var cursor = addrs
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK),
                  let raw = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard isCounted(name) else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (rx: data.ifi_ibytes, tx: data.ifi_obytes)
        }
        return result
    }
}

// MARK: - Per-process usage via a long-running nettop stream

final class NettopMonitor {
    let interval: Double
    private(set) var top: [ProcTraffic] = []
    /// True when nettop can't run or never produces data (e.g. under the App
    /// Sandbox, which denies the PTY and the network-statistics queries).
    private(set) var unavailable = false
    var onUpdate: (() -> Void)?

    private var parser = NettopStreamParser()
    private var process: Process?
    private var stopped = false
    private var hasEverEmitted = false
    private var failedLaunches = 0

    init(interval: Double) {
        self.interval = interval
    }

    func start() { launch() }

    func stop() {
        stopped = true
        process?.terminate()
    }

    private func launch() {
        guard !stopped else { return }
        let p = Process()
        // nettop block-buffers stdout when writing to a pipe, which would make
        // samples arrive in multi-second bursts. `script -q /dev/null` gives it
        // a PTY so every sample flushes immediately.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null",
                       "/usr/bin/nettop", "-P", "-d", "-x", "-J", "bytes_in,bytes_out",
                       "-s", String(Int(interval)), "-L", "0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {                      // EOF
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            // .common keeps updates flowing while the status menu is open.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                self?.ingest(text)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.failedLaunches += 1
                if !self.hasEverEmitted && self.failedLaunches >= 3 {
                    self.markUnavailable()         // keeps dying without data: give up
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.launch()                 // restart if nettop dies on us
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("Neticle: failed to launch nettop: \(error)")
            DispatchQueue.main.async { [weak self] in self?.markUnavailable() }
        }
    }

    private func markUnavailable() {
        guard !unavailable else { return }
        unavailable = true
        top = []
        onUpdate?()
    }

    private func ingest(_ text: String) {
        for block in parser.feed(text) {
            hasEverEmitted = true
            failedLaunches = 0
            top = Array(block.filter { $0.total > 0 }.prefix(5))
            onUpdate?()
        }
    }
}

// MARK: - State mirror for CLI verification

struct AppState: Codable {
    struct Entry: Codable {
        let name: String
        let pid: Int32
        let downMbps: Double
        let upMbps: Double
    }
    let updatedAt: Double
    let title: String
    let downMbps: Double
    let upMbps: Double
    let windowSeconds: Double
    let top: [Entry]
    let menuLines: [String]
    let nettopAvailable: Bool
    // Status item geometry as reported by AppKit — lets CLI QA confirm the
    // item really occupies a menu bar slot without screen-capture permissions.
    let itemVisible: Bool
    let itemFrame: [Double]      // [x, y, width, height], Cocoa coords
    let screenSize: [Double]     // [width, height] of the item's screen
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let rateSampler = NetworkRateSampler()
    private let monitor = NettopMonitor(interval: 2)
    private var downMbps = 0.0
    private var upMbps = 0.0

    private let menu = NSMenu()
    private let totalsItem = NSMenuItem()
    private let sectionItem = NSMenuItem()
    private var rowItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.title = statusTitle(downMbps: 0, upMbps: 0)
            button.toolTip = "Neticle — live network throughput. Click for top consumers."
        }
        buildMenu()
        statusItem.menu = menu

        _ = rateSampler.sample()                   // prime the counters
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)  // keep ticking while menu is open

        monitor.onUpdate = { [weak self] in self?.refreshRows() }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        totalsItem.isEnabled = false
        menu.addItem(totalsItem)
        menu.addItem(.separator())
        sectionItem.isEnabled = false
        menu.addItem(sectionItem)
        for _ in 0..<5 {
            let item = NSMenuItem()
            item.isEnabled = true                  // full-contrast text; click is a no-op
            item.isHidden = true
            rowItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Neticle", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        renderTotals()
        refreshRows()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func tick() {
        if let rate = rateSampler.sample() {
            downMbps = rate.downBytesPerSec * 8.0 / 1_000_000.0
            upMbps = rate.upBytesPerSec * 8.0 / 1_000_000.0
        }
        statusItem.button?.title = statusTitle(downMbps: downMbps, upMbps: upMbps)
        renderTotals()
        writeState()
    }

    private func renderTotals() {
        totalsItem.attributedTitle = NSAttributedString(
            string: totalsLine(downMbps: downMbps, upMbps: upMbps),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        sectionItem.attributedTitle = NSAttributedString(
            string: "TOP CONSUMERS — Mbps, last \(Int(monitor.interval)) s",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }

    private func currentMenuLines() -> [String] {
        monitor.unavailable
            ? ["Per-process stats unavailable in this build"]
            : consumerLines(monitor.top, interval: monitor.interval)
    }

    private func refreshRows() {
        let lines = currentMenuLines()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (index, item) in rowItems.enumerated() {
            if index < lines.count {
                item.attributedTitle = NSAttributedString(
                    string: lines[index],
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
        writeState()
    }

    private func writeState() {
        let entries = monitor.top.map {
            AppState.Entry(name: $0.name,
                           pid: $0.pid,
                           downMbps: mbps($0.bytesIn, over: monitor.interval),
                           upMbps: mbps($0.bytesOut, over: monitor.interval))
        }
        let itemWindow = statusItem?.button?.window
        let frame = itemWindow?.frame ?? .zero
        let screen = itemWindow?.screen?.frame.size ?? .zero
        let state = AppState(updatedAt: Date().timeIntervalSince1970,
                             title: statusItem?.button?.title ?? "",
                             downMbps: downMbps,
                             upMbps: upMbps,
                             windowSeconds: monitor.interval,
                             top: entries,
                             menuLines: currentMenuLines(),
                             nettopAvailable: !monitor.unavailable,
                             itemVisible: statusItem?.isVisible ?? false,
                             itemFrame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                             screenSize: [screen.width, screen.height])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
