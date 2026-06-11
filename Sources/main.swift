import AppKit
import SwiftUI

// Neticle — menu bar system stats.
// The status item shows whichever stats are pinned (network ↓/↑ Mbps by
// default); clicking it opens a SwiftUI popover with Network, CPU, Memory,
// and Disk sections, each with a top-5 list and row actions (terminate,
// view logs, reveal in Finder). State is mirrored to a JSON file so
// behaviour can be verified from the CLI.

// Overridable because the sandboxed (App Store) variant cannot write /tmp;
// QA scripts point this at a container path instead.
let statePath = ProcessInfo.processInfo.environment["NETICLE_STATE"] ?? "/tmp/neticle-state.json"

// MARK: - State mirror for CLI verification

struct AppState: Codable {
    struct NetEntry: Codable {
        let name: String
        let pid: Int32
        let downMbps: Double
        let upMbps: Double
    }
    struct ProcEntry: Codable {
        let name: String
        let pid: Int32
        let cpuPercent: Double
        let rssBytes: UInt64
    }
    struct DirEntry: Codable {
        let path: String
        let bytes: UInt64
    }
    let updatedAt: Double
    let title: String
    let pinned: [String]
    let downMbps: Double
    let upMbps: Double
    let windowSeconds: Double
    let top: [NetEntry]
    let menuLines: [String]
    let nettopAvailable: Bool
    let liveStream: Bool
    let cpuPercent: Double
    let cpuTop: [ProcEntry]
    let memUsedBytes: UInt64
    let memTotalBytes: UInt64
    let memTop: [ProcEntry]
    let diskUsedBytes: UInt64
    let diskTotalBytes: UInt64
    let diskTop: [DirEntry]
    let diskScan: String
    // Status item geometry as reported by AppKit — lets CLI QA confirm the
    // item really occupies a menu bar slot without screen-capture permissions.
    let itemVisible: Bool
    let itemFrame: [Double]      // [x, y, width, height], Cocoa coords
    let screenSize: [Double]     // [width, height] of the item's screen
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    static let popoverSize = NSSize(width: 380, height: 660)   // matches StatsView's fixed frame

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = StatsStore()

    private let rateSampler = NetworkRateSampler()
    // nettop's CSV one-shot takes a fixed ~5 s wall; a 6 s cadence avoids
    // overlapping runs so every snapshot lands and windows stay uniform.
    private let nettop = NettopMonitor(cadence: 6)
    private let cpuSampler = CPUSampler()
    private let processSampler = ProcessListSampler()
    private let diskScanner = DiskScanner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.toolTip = "Neticle — click for system stats"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = Self.popoverSize
        // Content is created lazily on open and torn down on close: a live
        // NSHostingView re-renders on every published sample even while the
        // popover is hidden, which costs real CPU in a 1 s-tick app.

        store.onPinnedChange = { [weak self] in
            self?.renderTitle()
            self?.writeState()
        }
        store.requestRescan = { [weak self] in self?.diskScanner.rescan() }

        nettop.onUpdate = { [weak self] in
            guard let self else { return }
            self.store.netTop = self.nettop.top
            self.store.netWindow = self.nettop.window
            self.store.nettopAvailable = !self.nettop.unavailable
            self.writeState()
        }
        nettop.start()

        diskScanner.onUpdate = { [weak self] in
            guard let self else { return }
            self.store.diskTop = self.diskScanner.top
            self.store.scanState = self.diskScanner.state
            self.writeState()
        }
        // No scan at launch: du touches TCC-protected folders (Desktop,
        // Documents, Downloads, app data), and each category triggers its own
        // macOS permission prompt. The user starts scans from the popover.

        _ = rateSampler.sample()                   // prime the counters
        _ = cpuSampler.sample()

        let fast = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.fastTick() }
        RunLoop.main.add(fast, forMode: .common)   // keep ticking while popover is open
        let slow = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.slowTick() }
        RunLoop.main.add(slow, forMode: .common)
        slowTick()
        renderTitle()
        installDebugSignals()
    }

    /// Headless QA hooks: SIGUSR1 toggles the popover, SIGUSR2 toggles the
    /// live nettop stream without UI involvement.
    private var signalSources: [DispatchSourceSignal] = []
    private func installDebugSignals() {
        for (sig, handler) in [(SIGUSR1, { [weak self] in self?.statusClicked() }),
                               (SIGUSR2, { [weak self] in
                                   guard let self else { return }
                                   self.nettop.isStreaming
                                       ? self.nettop.endLiveStream()
                                       : self.nettop.beginLiveStream()
                               })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        nettop.stop()
        diskScanner.cancel()
    }

    // MARK: Status item

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.delegate = self
            menu.addItem(withTitle: "Quit Neticle", action: #selector(quit), keyEquivalent: "q")
                .target = self
            // Attach the menu only for this click so left-clicks keep
            // toggling the popover; menuDidClose detaches it again.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            let hosting = NSHostingController(rootView: StatsView(store: store))
            // Keep the popover a fixed size: NSHostingController's automatic
            // preferredContentSize updates make NSPopover re-anchor and glitch
            // whenever rows change, so they're disabled outright.
            if #available(macOS 13.0, *) {
                hosting.sizingOptions = []
            }
            hosting.preferredContentSize = Self.popoverSize
            popover.contentViewController = hosting
            popover.contentSize = Self.popoverSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            nettop.beginLiveStream()    // fresh 2 s per-process data while visible
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        nettop.endLiveStream()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let segments = store.segments()
        if segments.count == 1 && segments[0].symbol == "chart.bar.fill" {
            // Nothing pinned: show just the logo glyph.
            button.title = ""
            button.image = NSImage(systemSymbolName: "chart.bar.fill",
                                   accessibilityDescription: "Neticle")
            button.image?.isTemplate = true
        } else {
            button.image = nil
            button.title = titlePlainText(segments)
        }
    }

    // MARK: Sampling ticks

    private func fastTick() {
        if let rate = rateSampler.sample() {
            store.downMbps = rate.downBytesPerSec * 8.0 / 1_000_000.0
            store.upMbps = rate.upBytesPerSec * 8.0 / 1_000_000.0
        }
        renderTitle()
        writeState()
    }

    private func slowTick() {
        if let cpu = cpuSampler.sample() {
            store.cpuPercent = cpu
        }
        if let mem = sampleMemory() {
            store.memory = mem
        }
        if let disk = sampleDisk() {
            store.disk = disk
        }
        // Neticle's own footprint (the app plus its nettop/du helpers) is
        // hidden from the top lists — seeing the monitor's sampler ranked #1
        // confused more than it informed. Totals still include everything.
        // The exclusion set is built when ps results arrive, not when the
        // tick starts, so helpers spawned in between are still caught.
        processSampler.sample { [weak self] procs in
            guard let self else { return }
            var ownPids = Set(self.nettop.helperPids)
            ownPids.insert(ProcessInfo.processInfo.processIdentifier)
            if let duPid = self.diskScanner.helperPid { ownPids.insert(duPid) }
            let visible = procs.filter { !ownPids.contains($0.pid) }
            self.store.cpuTop = topByCPU(visible)
            self.store.memTop = topByMemory(visible)
        }
    }

    // MARK: State mirror

    private func writeState() {
        let netEntries = store.netTop.map {
            AppState.NetEntry(name: $0.name, pid: $0.pid,
                              downMbps: mbps($0.bytesIn, over: store.netWindow),
                              upMbps: mbps($0.bytesOut, over: store.netWindow))
        }
        let scanLabel: String
        switch store.scanState {
        case .idle: scanLabel = "idle"
        case .scanning: scanLabel = "scanning"
        case .done: scanLabel = "done"
        }
        let itemWindow = statusItem?.button?.window
        let frame = itemWindow?.frame ?? .zero
        let screen = itemWindow?.screen?.frame.size ?? .zero
        let state = AppState(
            updatedAt: Date().timeIntervalSince1970,
            title: titlePlainText(store.segments()),
            pinned: store.pinned.map(\.rawValue).sorted(),
            downMbps: store.downMbps,
            upMbps: store.upMbps,
            windowSeconds: store.netWindow,
            top: netEntries,
            menuLines: store.nettopAvailable
                ? consumerLines(store.netTop, interval: store.netWindow)
                : ["Per-process stats unavailable in this build"],
            nettopAvailable: store.nettopAvailable,
            liveStream: nettop.isStreaming,
            cpuPercent: store.cpuPercent,
            cpuTop: store.cpuTop.map { AppState.ProcEntry(name: $0.name, pid: $0.pid,
                                                          cpuPercent: $0.cpuPercent, rssBytes: $0.rssBytes) },
            memUsedBytes: store.memory?.usedBytes ?? 0,
            memTotalBytes: store.memory?.totalBytes ?? 0,
            memTop: store.memTop.map { AppState.ProcEntry(name: $0.name, pid: $0.pid,
                                                          cpuPercent: $0.cpuPercent, rssBytes: $0.rssBytes) },
            diskUsedBytes: store.disk?.usedBytes ?? 0,
            diskTotalBytes: store.disk?.totalBytes ?? 0,
            diskTop: store.diskTop.map { AppState.DirEntry(path: $0.path, bytes: $0.bytes) },
            diskScan: scanLabel,
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
