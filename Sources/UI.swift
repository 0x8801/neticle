import SwiftUI
import AppKit

// MARK: - Observable model backing the popover and the menu bar title

final class StatsStore: ObservableObject {
    // Network
    @Published var downMbps = 0.0
    @Published var upMbps = 0.0
    @Published var netTop: [ProcTraffic] = []
    @Published var nettopAvailable = true
    @Published var netWindow: Double = 3

    // CPU
    @Published var cpuPercent = 0.0
    @Published var cpuTop: [PsProc] = []

    // Memory
    @Published var memory: MemoryUsage?
    @Published var memTop: [PsProc] = []

    // Disk
    @Published var disk: DiskUsage?
    @Published var diskTop: [DirSize] = []
    @Published var scanState: DiskScanner.State = .idle

    // Internet
    @Published var online = true
    @Published var latencyMs: Double?
    @Published var latencyHistory: [Double?] = []
    @Published var outageText = "none recorded yet"
    @Published var ipDetails: IPDetails?
    @Published var ipFetching = false

    // Kill-button arming (two-step confirm), keyed by pid so it survives
    // the periodic re-sorting of rows.
    @Published var armedKillPid: Int32?
    @Published var lastActionError: String?

    // Pinned stats shown in the menu bar
    @Published var pinned: Set<StatKind> {
        didSet {
            UserDefaults.standard.set(pinned.map(\.rawValue).sorted(), forKey: "pinnedStats")
            onPinnedChange?()
        }
    }
    var onPinnedChange: (() -> Void)?
    var requestRescan: (() -> Void)?
    var requestIPRefresh: (() -> Void)?
    var openPreferences: (() -> Void)?

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "pinnedStats") {
            pinned = Set(saved.compactMap(StatKind.init(rawValue:)))
        } else {
            pinned = [.network]
        }
    }

    func togglePin(_ kind: StatKind) {
        if pinned.contains(kind) { pinned.remove(kind) } else { pinned.insert(kind) }
    }

    func requestKill(pid: Int32) {
        if armedKillPid == pid {
            armedKillPid = nil
            lastActionError = ProcessActions.terminate(pid: pid)
        } else {
            armedKillPid = pid
            lastActionError = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.armedKillPid == pid { self?.armedKillPid = nil }
            }
        }
    }

    var memPercent: Double { memory?.percent ?? 0 }
    var diskPercent: Double { disk?.percent ?? 0 }
}

// MARK: - Popover root

struct StatsView: View {
    @ObservedObject var store: StatsStore
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if settings.enabledSections.contains(.network) { networkSection }
                    if settings.enabledSections.contains(.internet) { internetSection }
                    if settings.enabledSections.contains(.cpu) { cpuSection }
                    if settings.enabledSections.contains(.memory) { memorySection }
                    if settings.enabledSections.contains(.disk) { diskSection }
                    if settings.enabledSections.isEmpty {
                        NoticeRow(text: "All sections are turned off — see Preferences")
                            .padding(.vertical, 30)
                    }
                }
                .padding(12)
            }
            Divider().padding(.horizontal, 12)
            footer
        }
        // Fixed height, flexible width: NSPopover re-anchors (and visibly
        // glitches) every time the hosting view's preferred size changes, so
        // nothing here may resize itself — but the width must adapt to
        // whatever the popover actually provides (it insets content slightly
        // on some macOS versions, and a hard width would clip the edges).
        .frame(minWidth: 340, maxWidth: 380, minHeight: 660, maxHeight: 660)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.linearGradient(colors: [.green, .teal, .orange],
                                                 startPoint: .bottomLeading, endPoint: .topTrailing))
            Text("Neticle").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            if let error = store.lastActionError {
                Text(error).font(.caption2).foregroundColor(.red).lineLimit(1)
            }
            Button { store.openPreferences?() } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Preferences")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Quit Neticle")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(.caption2).foregroundColor(.secondary)
            Spacer()
            Text("Click a stat's pin to show it in the menu bar")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Sections

    private var networkSection: some View {
        Section1(kind: .network, symbol: "arrow.up.arrow.down.circle.fill", tint: .green,
                 title: "Network",
                 value: "↓ \(fmtMbps(store.downMbps))  ↑ \(fmtMbps(store.upMbps)) Mbps",
                 store: store) {
            if !store.nettopAvailable {
                NoticeRow(text: "Per-process stats unavailable in this build")
            } else if store.netTop.isEmpty {
                NoticeRow(text: "No measurable traffic yet…")
            } else {
                ForEach(store.netTop, id: \.pid) { proc in
                    ProcessRow(name: proc.name, pid: proc.pid,
                               value: "↓ \(fmtMbps(mbps(proc.bytesIn, over: store.netWindow)))  ↑ \(fmtMbps(mbps(proc.bytesOut, over: store.netWindow)))",
                               fraction: nil, store: store)
                }
            }
        }
    }

    private var cpuSection: some View {
        Section1(kind: .cpu, symbol: "cpu.fill", tint: .teal,
                 title: "CPU", value: fmtPercent(store.cpuPercent),
                 fraction: store.cpuPercent / 100, store: store) {
            if store.cpuTop.isEmpty {
                NoticeRow(text: "No process data available")
            } else {
                ForEach(store.cpuTop, id: \.pid) { proc in
                    ProcessRow(name: proc.name, pid: proc.pid,
                               value: String(format: "%.1f%%", proc.cpuPercent),
                               fraction: min(proc.cpuPercent / 100, 1), store: store)
                }
            }
        }
    }

    private var memorySection: some View {
        Section1(kind: .memory, symbol: "memorychip.fill", tint: .purple,
                 title: "Memory",
                 value: store.memory.map { "\(bytesHuman($0.usedBytes)) of \(bytesHuman($0.totalBytes))" } ?? "—",
                 fraction: store.memPercent / 100, store: store) {
            if store.memTop.isEmpty {
                NoticeRow(text: "No process data available")
            } else {
                ForEach(store.memTop, id: \.pid) { proc in
                    ProcessRow(name: proc.name, pid: proc.pid,
                               value: bytesHuman(proc.rssBytes),
                               fraction: store.memory.map { min(Double(proc.rssBytes) / Double($0.totalBytes), 1) },
                               store: store)
                }
            }
        }
    }

    private var diskSection: some View {
        Section1(kind: .disk, symbol: "internaldrive.fill", tint: .orange,
                 title: "Disk",
                 value: store.disk.map { "\(bytesHuman($0.usedBytes)) of \(bytesHuman($0.totalBytes))" } ?? "—",
                 fraction: store.diskPercent / 100, store: store,
                 accessory: { AnyView(diskAccessory) }) {
            if store.diskTop.isEmpty {
                if store.scanState == .scanning {
                    NoticeRow(text: "Scanning your home folder…")
                } else {
                    // Scanning is opt-in: it reads Desktop/Documents/Downloads
                    // and app data, so macOS shows permission prompts — they
                    // should happen on the user's click, not at launch.
                    VStack(spacing: 6) {
                        NoticeRow(text: "Find the largest folders in your home directory")
                        Button("Scan largest folders") { store.requestRescan?() }
                            .controlSize(.small)
                        Text("macOS may ask to allow access to your folders")
                            .font(.system(size: 10))
                            .foregroundColor(Color.secondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
            } else {
                ForEach(store.diskTop, id: \.path) { dir in
                    FolderRow(dir: dir)
                }
            }
        }
    }

    private var internetSection: some View {
        Section1(kind: .internet, symbol: "wifi", tint: .blue,
                 title: "Internet",
                 value: store.online ? "Online · \(fmtLatency(store.latencyMs))" : "Offline",
                 valueTint: store.online ? .green : .red,
                 store: store,
                 accessory: { AnyView(ipRefreshAccessory) }) {
            VStack(alignment: .leading, spacing: 5) {
                SparklineView(values: store.latencyHistory)
                    .frame(height: 32)
                HStack(spacing: 6) {
                    Image(systemName: "number").font(.system(size: 10))
                        .foregroundColor(.blue.opacity(0.8)).frame(width: 13)
                    Text(store.ipDetails?.ip ?? (store.ipFetching ? "Looking up…" : "—"))
                        .font(.system(size: 12).monospacedDigit())
                    Spacer(minLength: 8)
                    if let ip = store.ipDetails {
                        Text("\(ip.flag) \([ip.city, ip.country].filter { !$0.isEmpty }.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(height: 20)
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 10))
                        .foregroundColor(.blue.opacity(0.8)).frame(width: 13)
                    Text(store.ipDetails?.isp.isEmpty == false ? store.ipDetails!.isp : "—")
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("ISP").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .frame(height: 20)
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.85)).frame(width: 13)
                    Text("Outages: \(store.outageText)")
                        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 18)
            }
        }
    }

    private var ipRefreshAccessory: some View {
        Button { store.requestIPRefresh?() } label: {
            if store.ipFetching {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help("Refresh IP details")
        .disabled(store.ipFetching)
    }

    private var diskAccessory: some View {
        Button {
            store.requestRescan?()
        } label: {
            if store.scanState == .scanning {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help("Rescan largest folders")
        .disabled(store.scanState == .scanning)
    }
}

// MARK: - Section container

private struct Section1<Rows: View>: View {
    let kind: StatKind
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    var valueTint: Color?
    var fraction: Double?
    @ObservedObject var store: StatsStore
    var accessory: (() -> AnyView)?
    @ViewBuilder let rows: Rows

    init(kind: StatKind, symbol: String, tint: Color, title: String, value: String,
         valueTint: Color? = nil, fraction: Double? = nil, store: StatsStore,
         accessory: (() -> AnyView)? = nil, @ViewBuilder rows: () -> Rows) {
        self.kind = kind
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.value = value
        self.valueTint = valueTint
        self.fraction = fraction
        self.store = store
        self.accessory = accessory
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let accessory { accessory() }
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(valueTint ?? .secondary)
                PinButton(kind: kind, store: store)
            }
            if let fraction {
                UsageBar(fraction: fraction, tint: tint)
            }
            VStack(spacing: 2) { rows }
                .frame(maxWidth: .infinity)
                .padding(8)
                // Constant card height (5 rows) so sections don't grow and
                // shrink as lists change — that reflow read as "UI shifting".
                .frame(height: 134, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.045)))
        }
    }
}

private struct PinButton: View {
    let kind: StatKind
    @ObservedObject var store: StatsStore

    var body: some View {
        let isPinned = store.pinned.contains(kind)
        Button { store.togglePin(kind) } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isPinned ? .accentColor : .secondary)
                .rotationEffect(.degrees(45))
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin from menu bar" : "Pin to menu bar")
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.65), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: - Rows

private struct ProcessRow: View {
    let name: String
    let pid: Int32
    let value: String
    var fraction: Double?
    @ObservedObject var store: StatsStore
    @State private var hovered = false

    var body: some View {
        let armed = store.armedKillPid == pid
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            HStack(spacing: 5) {
                Button { ProcessActions.viewLogs(pid: pid, name: name) } label: {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("View recent logs (Console)")

                Button { store.requestKill(pid: pid) } label: {
                    Image(systemName: armed ? "exclamationmark.octagon.fill" : "xmark.circle")
                        .font(.system(size: 11, weight: armed ? .bold : .regular))
                }
                .buttonStyle(.plain)
                .foregroundColor(armed ? .red : .secondary)
                .help(armed ? "Click again to terminate \(name)" : "Terminate process")
            }
            .opacity(hovered || armed ? 1 : 0)
            .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct FolderRow: View {
    let dir: DirSize
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange.opacity(0.8))
            Text(dir.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(dir.path)
            Spacer(minLength: 8)
            Text(bytesHuman(dir.bytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            Button { ProcessActions.revealInFinder(path: dir.path) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Show in Finder")
            .opacity(hovered ? 1 : 0)
            .frame(width: 18, alignment: .trailing)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct NoticeRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 22)
    }
}

// MARK: - Latency sparkline

struct SparklineView: View {
    let values: [Double?]

    var body: some View {
        GeometryReader { geo in
            let inset = CGSize(width: geo.size.width - 8, height: geo.size.height - 8)
            let plot = sparklineSegments(values, in: inset)
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                if values.count < 2 {
                    Text("Collecting latency samples…")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    ForEach(Array(plot.lines.enumerated()), id: \.offset) { _, line in
                        Path { path in path.addLines(line) }
                            .stroke(Color.blue.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .offset(x: 4, y: 4)
                    }
                    ForEach(Array(plot.offlineXs.enumerated()), id: \.offset) { _, x in
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: inset.height))
                        }
                        .stroke(Color.red.opacity(0.55), lineWidth: 1.5)
                        .offset(x: 4, y: 4)
                    }
                }
            }
        }
    }
}

// MARK: - Preferences

struct PrefsView: View {
    @ObservedObject var settings: Settings

    private static let sectionNames: [(StatKind, String)] = [
        (.network, "Network"), (.internet, "Internet"), (.cpu, "CPU"),
        (.memory, "Memory"), (.disk, "Disk"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sections").font(.headline)
            ForEach(Self.sectionNames, id: \.0) { kind, name in
                Toggle(name, isOn: sectionBinding(kind))
            }
            Text("Hiding a section also stops its sampling. Pinned stats of hidden sections leave the menu bar.")
                .font(.caption2).foregroundColor(.secondary)

            Divider()

            Text("Refresh intervals").font(.headline)
            intervalRow("Processes (CPU & memory)", $settings.psInterval, [1, 2, 3, 5, 10])
            intervalRow("Network per-process snapshots", $settings.snapshotCadence, [6, 10, 15, 30])
            intervalRow("Connectivity probe", $settings.probeInterval, [10, 30, 60, 120])

            Divider()

            Toggle("Launch Neticle at login", isOn: loginBinding)
                .disabled(!Settings.loginItemSupported)
            if !Settings.loginItemSupported {
                Text("Requires macOS 13 or newer.")
                    .font(.caption2).foregroundColor(.secondary)
            } else if let error = settings.launchAtLoginError {
                Text(error).font(.caption2).foregroundColor(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func intervalRow(_ label: String, _ value: Binding<Double>, _ choices: [Double]) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Picker("", selection: value) {
                ForEach(choices, id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            .labelsHidden()
            .frame(width: 80)
        }
    }

    private func sectionBinding(_ kind: StatKind) -> Binding<Bool> {
        Binding(get: { settings.enabledSections.contains(kind) },
                set: { _ in settings.toggleSection(kind) })
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { settings.launchAtLogin },
                set: { settings.applyLaunchAtLogin($0) })
    }
}
