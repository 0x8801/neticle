import AppKit
import SwiftUI
import Combine

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
    let enabled: [String]
    let psInterval: Double
    let snapshotCadence: Double
    let probeInterval: Double
    let online: Bool
    let latencyMs: Double?
    let ip: String?
    let ipCity: String?
    let ipCountry: String?
    let isp: String?
    let outageCount: Int
    let latencySamples: Int
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
    private let settings = Settings()
    private var prefsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var slowTimer: Timer?

    private let rateSampler = NetworkRateSampler()
    // nettop's CSV one-shot takes a fixed ~5 s wall; a 6 s cadence avoids
    // overlapping runs so every snapshot lands and windows stay uniform.
    private let nettop = NettopMonitor(cadence: 6)
    private let cpuSampler = CPUSampler()
    private let processSampler = ProcessListSampler()
    private let diskScanner = DiskScanner()
    private let connectivity = ConnectivityMonitor()
    private let ipFetcher = IPInfoFetcher()

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
        store.requestIPRefresh = { [weak self] in self?.ipFetcher.fetch(force: true) }
        store.openPreferences = { [weak self] in self?.showPreferences() }

        nettop.onUpdate = { [weak self] in
            guard let self else { return }
            self.store.netTop = self.nettop.top
            self.store.netWindow = self.nettop.window
            self.store.nettopAvailable = !self.nettop.unavailable
            self.writeState()
        }
        if settings.enabledSections.contains(.network) {
            nettop.start()
        }

        connectivity.onUpdate = { [weak self] in
            guard let self else { return }
            self.store.online = self.connectivity.online
            self.store.latencyMs = self.connectivity.latencyMs
            self.store.latencyHistory = self.connectivity.history.map(\.latencyMs)
            self.store.outageText = Self.outageSummary(self.connectivity.outages)
            self.renderTitle()
            self.writeState()
        }
        connectivity.onReconnect = { [weak self] in self?.ipFetcher.fetch(force: true) }
        ipFetcher.onUpdate = { [weak self] in
            guard let self else { return }
            self.store.ipDetails = self.ipFetcher.details
            self.store.ipFetching = self.ipFetcher.fetching
            self.writeState()
        }
        connectivity.setProbeInterval(settings.probeInterval)
        if settings.enabledSections.contains(.internet) {
            connectivity.start()
            ipFetcher.fetch()
        }
        bindSettings()

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
        rescheduleSlowTimer()
        slowTick()
        renderTitle()
        installDebugSignals()
    }

    private func rescheduleSlowTimer() {
        slowTimer?.invalidate()
        let slow = Timer(timeInterval: settings.psInterval, repeats: true) { [weak self] _ in
            self?.slowTick()
        }
        RunLoop.main.add(slow, forMode: .common)
        slowTimer = slow
    }

    /// Live-applies preference changes: intervals reschedule their timers,
    /// section toggles start/stop the corresponding samplers.
    private func bindSettings() {
        settings.$psInterval
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rescheduleSlowTimer() } }
            .store(in: &cancellables)
        settings.$snapshotCadence
            .removeDuplicates()
            .sink { [weak self] cadence in
                DispatchQueue.main.async { self?.nettop.setCadence(cadence) }
            }
            .store(in: &cancellables)
        settings.$probeInterval
            .removeDuplicates()
            .sink { [weak self] interval in
                DispatchQueue.main.async { self?.connectivity.setProbeInterval(interval) }
            }
            .store(in: &cancellables)
        settings.$enabledSections
            .removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async { self?.applySections(enabled) }
            }
            .store(in: &cancellables)
    }

    private func applySections(_ enabled: Set<StatKind>) {
        if enabled.contains(.network) {
            nettop.start()
            if popover.isShown { nettop.beginLiveStream() }
        } else {
            nettop.stop()
        }
        if enabled.contains(.internet) {
            connectivity.start()
            ipFetcher.fetch()
        } else {
            connectivity.stop()
        }
        renderTitle()
        writeState()
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
            menu.addItem(withTitle: "Preferences…", action: #selector(showPrefsItem), keyEquivalent: ",")
                .target = self
            menu.addItem(.separator())
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
            let hosting = NSHostingController(rootView: StatsView(store: store, settings: settings))
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
            if settings.enabledSections.contains(.network) {
                nettop.beginLiveStream()    // fresh 2 s per-process data while visible
            }
        }
    }

    @objc private func showPrefsItem() {
        showPreferences()
    }

    private func showPreferences() {
        popover.performClose(nil)
        if prefsWindow == nil {
            let hosting = NSHostingController(rootView: PrefsView(settings: settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Neticle Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            prefsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    private static func outageSummary(_ outages: [ConnectivityMonitor.Outage]) -> String {
        guard let last = outages.last else { return "none recorded yet" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let when = formatter.string(from: last.start)
        let duration: String
        if let end = last.end {
            let seconds = Int(end.timeIntervalSince(last.start))
            duration = seconds < 60 ? "\(max(seconds, 1)) s" : "\(seconds / 60) min"
        } else {
            duration = "ongoing"
        }
        return "\(outages.count) · last at \(when) (\(duration))"
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

    private func currentSegments() -> [TitleSegment] {
        titleSegments(pinned: store.pinned,
                      enabled: settings.enabledSections,
                      downMbps: store.downMbps, upMbps: store.upMbps,
                      cpuPercent: store.cpuPercent,
                      memPercent: store.memPercent,
                      diskPercent: store.diskPercent,
                      online: store.online,
                      latencyMs: store.latencyMs)
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let segments = currentSegments()
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
        let enabled = settings.enabledSections
        if enabled.contains(.cpu), let cpu = cpuSampler.sample() {
            store.cpuPercent = cpu
        }
        if enabled.contains(.memory), let mem = sampleMemory() {
            store.memory = mem
        }
        if enabled.contains(.disk), let disk = sampleDisk() {
            store.disk = disk
        }
        guard enabled.contains(.cpu) || enabled.contains(.memory) else { return }
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
            title: titlePlainText(currentSegments()),
            pinned: store.pinned.map(\.rawValue).sorted(),
            enabled: settings.enabledSections.map(\.rawValue).sorted(),
            psInterval: settings.psInterval,
            snapshotCadence: settings.snapshotCadence,
            probeInterval: settings.probeInterval,
            online: store.online,
            latencyMs: store.latencyMs,
            ip: store.ipDetails?.ip,
            ipCity: store.ipDetails?.city,
            ipCountry: store.ipDetails?.country,
            isp: store.ipDetails?.isp,
            outageCount: connectivity.outages.count,
            latencySamples: connectivity.history.count,
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
