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

    func segments() -> [TitleSegment] {
        titleSegments(pinned: pinned, downMbps: downMbps, upMbps: upMbps,
                      cpuPercent: cpuPercent, memPercent: memPercent, diskPercent: diskPercent)
    }
}

// MARK: - Popover root

struct StatsView: View {
    @ObservedObject var store: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    networkSection
                    cpuSection
                    memorySection
                    diskSection
                }
                .padding(12)
            }
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 380)
        .frame(maxHeight: 640)
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
                NoticeRow(text: store.scanState == .scanning
                          ? "Scanning your home folder…"
                          : "Largest folders appear here after a scan")
            } else {
                ForEach(store.diskTop, id: \.path) { dir in
                    FolderRow(dir: dir)
                }
            }
        }
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
    var fraction: Double?
    @ObservedObject var store: StatsStore
    var accessory: (() -> AnyView)?
    @ViewBuilder let rows: Rows

    init(kind: StatKind, symbol: String, tint: Color, title: String, value: String,
         fraction: Double? = nil, store: StatsStore,
         accessory: (() -> AnyView)? = nil, @ViewBuilder rows: () -> Rows) {
        self.kind = kind
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.value = value
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
                    .foregroundColor(.secondary)
                PinButton(kind: kind, store: store)
            }
            if let fraction {
                UsageBar(fraction: fraction, tint: tint)
            }
            VStack(spacing: 2) { rows }
                .padding(8)
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
