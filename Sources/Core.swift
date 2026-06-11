import Foundation

// Shared, UI-free core: nettop CSV stream parsing and formatting helpers.
//
// `nettop -P -d -x -J bytes_in,bytes_out -L 0` emits sample blocks like:
//
//   time,,bytes_in,bytes_out,
//   23:31:57.690382,launchd.1,0,0,
//   23:31:57.690392,Spotify.1579,485213,201259,
//   time,,bytes_in,bytes_out,            <- header repeats per sample block
//   ...
//
// The first block holds totals since boot; with -d every later block holds
// deltas over the sample window. nettop truncates process names to ~15 chars.

struct ProcTraffic: Equatable {
    let name: String
    let pid: Int32
    let bytesIn: UInt64
    let bytesOut: UInt64
    var total: UInt64 { bytesIn &+ bytesOut }
}

struct NettopStreamParser {
    private var pending = ""
    private var currentRows: [ProcTraffic] = []
    private var headersSeen = 0

    /// Feed a raw stdout chunk; returns any completed delta blocks,
    /// each sorted by total bytes descending. The boot-totals block is dropped.
    /// Handles both \n and PTY \r\n endings — note Swift folds "\r\n" into a
    /// single Character, so a plain firstIndex(of: "\n") would never match it.
    mutating func feed(_ chunk: String) -> [[ProcTraffic]] {
        pending += chunk
        var blocks: [[ProcTraffic]] = []
        while let newline = pending.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            if let block = consume(line: line) {
                blocks.append(block)
            }
        }
        return blocks
    }

    private mutating func consume(line rawLine: String) -> [ProcTraffic]? {
        // .whitespacesAndNewlines also strips the \r left by PTY line endings.
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        if line.hasPrefix("time,") {
            let finished = currentRows
            currentRows = []
            headersSeen += 1
            // The block between headers 1 and 2 is totals-since-boot: drop it.
            if headersSeen >= 3 && !finished.isEmpty {
                return finished.sorted { $0.total > $1.total }
            }
            return nil
        }
        if let row = Self.parseRow(line) {
            currentRows.append(row)
        }
        return nil
    }

    /// Parses "<time>,<name>.<pid>,<bytes_in>,<bytes_out>," — the name may
    /// itself contain dots or commas.
    static func parseRow(_ line: String) -> ProcTraffic? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        guard fields.count >= 4,
              let bytesOut = UInt64(fields[fields.count - 1]),
              let bytesIn = UInt64(fields[fields.count - 2]) else { return nil }
        let nameField = fields[1 ..< fields.count - 2].joined(separator: ",")
        guard !nameField.isEmpty else { return nil }
        let (name, pid) = splitNamePid(nameField)
        return ProcTraffic(name: name, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    static func splitNamePid(_ field: String) -> (String, Int32) {
        if let dot = field.lastIndex(of: "."),
           let pid = Int32(field[field.index(after: dot)...]) {
            return (String(field[..<dot]), pid)
        }
        return (field, -1)
    }
}

// MARK: - Formatting

func mbps(_ bytes: UInt64, over seconds: Double) -> Double {
    guard seconds > 0 else { return 0 }
    return Double(bytes) * 8.0 / seconds / 1_000_000.0
}

func fmtMbps(_ value: Double) -> String {
    value >= 99.95 ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

func rpad(_ s: String, _ width: Int) -> String {
    if s.count > width { return String(s.prefix(width - 1)) + "…" }
    return s + String(repeating: " ", count: width - s.count)
}

func lpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

func statusTitle(downMbps: Double, upMbps: Double) -> String {
    "↓ \(fmtMbps(downMbps)) ↑ \(fmtMbps(upMbps)) Mbps"
}

func totalsLine(downMbps: Double, upMbps: Double) -> String {
    "Total   ↓ \(fmtMbps(downMbps)) Mbps   ↑ \(fmtMbps(upMbps)) Mbps"
}

/// Menu rows for the top consumers, e.g. "1. Spotify            ↓  1.9  ↑  0.8"
func consumerLines(_ top: [ProcTraffic], interval: Double, maxRows: Int = 5) -> [String] {
    let rows = top.prefix(maxRows)
    if rows.isEmpty { return ["No measurable traffic yet…"] }
    return rows.enumerated().map { index, p in
        let down = lpad(fmtMbps(mbps(p.bytesIn, over: interval)), 5)
        let up = lpad(fmtMbps(mbps(p.bytesOut, over: interval)), 5)
        return "\(index + 1). \(rpad(p.name, 17)) ↓\(down)  ↑\(up)"
    }
}

/// Rows of a single one-shot snapshot (`nettop -P -x -J bytes_in,bytes_out -L 1`):
/// cumulative per-process byte counters. Streaming nettop (-L 0) burns >100%
/// CPU in its event loop, so the app takes cheap snapshots and diffs them.
func parseNettopSnapshot(_ text: String) -> [ProcTraffic] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("time,") { return nil }
        return NettopStreamParser.parseRow(trimmed)
    }
}

/// Per-process byte deltas between two snapshots keyed by "pid|name".
/// Processes seen for the first time are skipped; counters that went
/// backwards (pid reuse) clamp to zero.
func diffSnapshots(previous: [String: ProcTraffic],
                   current: [String: ProcTraffic]) -> [ProcTraffic] {
    current.compactMap { key, cur in
        guard let prev = previous[key] else { return nil }
        let dIn = cur.bytesIn >= prev.bytesIn ? cur.bytesIn - prev.bytesIn : 0
        let dOut = cur.bytesOut >= prev.bytesOut ? cur.bytesOut - prev.bytesOut : 0
        return ProcTraffic(name: cur.name, pid: cur.pid, bytesIn: dIn, bytesOut: dOut)
    }
}

func snapshotKey(_ p: ProcTraffic) -> String { "\(p.pid)|\(p.name)" }

// MARK: - Process CPU/RAM sampling (parsed from `ps -Aceo pcpu=,rss=,pid=,comm=`)

struct PsProc: Equatable {
    let name: String
    let pid: Int32
    let cpuPercent: Double
    let rssBytes: UInt64
}

/// Each row is "<pcpu> <rss-KB> <pid> <comm…>" — comm may contain spaces,
/// which is why the numeric fields come first.
func parsePsRows(_ output: String) -> [PsProc] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4,
              let cpu = Double(fields[0]),
              let rssKB = UInt64(fields[1]),
              let pid = Int32(fields[2]) else { return nil }
        let name = fields[3...].joined(separator: " ")
        return PsProc(name: name, pid: pid, cpuPercent: cpu, rssBytes: rssKB * 1024)
    }
}

func topByCPU(_ procs: [PsProc], maxRows: Int = 5) -> [PsProc] {
    Array(procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(maxRows))
}

func topByMemory(_ procs: [PsProc], maxRows: Int = 5) -> [PsProc] {
    Array(procs.sorted { $0.rssBytes > $1.rssBytes }.prefix(maxRows))
}

// MARK: - Disk usage scan (parsed from `du -x -k -d 1 <roots…>`)

struct DirSize: Equatable {
    let path: String
    let bytes: UInt64
    var displayName: String { (path as NSString).lastPathComponent }
}

/// Rows are "<KB>\t<path>". The roots themselves (aggregate totals) are
/// dropped, as are hidden directories — they're not actionable in Finder.
func parseDuRows(_ output: String, roots: [String], maxRows: Int = 5) -> [DirSize] {
    let rootSet = Set(roots.map { ($0 as NSString).standardizingPath })
    let entries: [DirSize] = output.split(whereSeparator: \.isNewline).compactMap { line in
        guard let tab = line.firstIndex(of: "\t"),
              let kb = UInt64(line[..<tab]) else { return nil }
        let path = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
        let standardized = (path as NSString).standardizingPath
        guard !rootSet.contains(standardized),
              !(standardized as NSString).lastPathComponent.hasPrefix(".") else { return nil }
        return DirSize(path: standardized, bytes: kb * 1024)
    }
    return Array(entries.sorted { $0.bytes > $1.bytes }.prefix(maxRows))
}

// MARK: - Human formatting

func bytesHuman(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 100 { return String(format: "%.0f GB", gb) }
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

func fmtPercent(_ value: Double) -> String {
    String(format: "%.0f%%", min(max(value, 0), 999))
}

// MARK: - IP details (parsed from ipwho.is / ipapi.co JSON)

struct IPDetails: Equatable {
    let ip: String
    let city: String
    let country: String
    let countryCode: String
    let isp: String
    var flag: String { flagEmoji(countryCode) }
}

func parseIPWhoIs(_ data: Data) -> IPDetails? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          (json["success"] as? Bool) != false,
          let ip = json["ip"] as? String, !ip.isEmpty else { return nil }
    let connection = json["connection"] as? [String: Any]
    return IPDetails(ip: ip,
                     city: json["city"] as? String ?? "",
                     country: json["country"] as? String ?? "",
                     countryCode: json["country_code"] as? String ?? "",
                     isp: (connection?["isp"] as? String)
                        ?? (connection?["org"] as? String) ?? "")
}

func parseIPApiCo(_ data: Data) -> IPDetails? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let ip = json["ip"] as? String, !ip.isEmpty else { return nil }
    return IPDetails(ip: ip,
                     city: json["city"] as? String ?? "",
                     country: json["country_name"] as? String ?? "",
                     countryCode: json["country_code"] as? String ?? "",
                     isp: json["org"] as? String ?? "")
}

/// "KE" → 🇰🇪 via regional indicator symbols; empty/invalid → "".
func flagEmoji(_ countryCode: String) -> String {
    let code = countryCode.uppercased()
    guard code.count == 2, code.allSatisfy({ $0.isLetter && $0.isASCII }) else { return "" }
    return String(code.unicodeScalars.compactMap {
        Unicode.Scalar(0x1F1E6 + $0.value - Unicode.Scalar("A").value).map(Character.init)
    })
}

// MARK: - Connectivity history → sparkline geometry

/// Latency history → line segments for a sparkline. `nil` samples (offline)
/// split the line and are returned as x positions for offline markers.
/// Y is normalized to max(observed, 100 ms) so quiet links don't look spiky.
func sparklineSegments(_ values: [Double?], in size: CGSize)
    -> (lines: [[CGPoint]], offlineXs: [CGFloat]) {
    guard values.count > 1, size.width > 0, size.height > 0 else { return ([], []) }
    let maxValue = max(values.compactMap { $0 }.max() ?? 100, 100)
    let stepX = size.width / CGFloat(values.count - 1)
    var lines: [[CGPoint]] = []
    var current: [CGPoint] = []
    var offlineXs: [CGFloat] = []
    for (index, value) in values.enumerated() {
        let x = CGFloat(index) * stepX
        if let v = value {
            let clamped = min(max(v, 0), maxValue)
            let y = size.height - CGFloat(clamped / maxValue) * size.height
            current.append(CGPoint(x: x, y: y))
        } else {
            offlineXs.append(x)
            if current.count > 1 { lines.append(current) }
            current = []
        }
    }
    if current.count > 1 { lines.append(current) }
    return (lines, offlineXs)
}

func fmtLatency(_ ms: Double?) -> String {
    guard let ms else { return "—" }
    return ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms"
}

// MARK: - Pinned menu bar title

enum StatKind: String, CaseIterable, Codable {
    case network, cpu, memory, disk, internet
}

struct TitleSegment: Equatable {
    let symbol: String   // SF Symbol name rendered before the text
    let text: String     // "" for the logo-only segment
}

/// Builds the menu bar segments for the pinned stats, in canonical order.
/// Disabled sections can't contribute even if pinned. With nothing shown,
/// the bar falls back to the Neticle glyph.
func titleSegments(pinned: Set<StatKind>,
                   enabled: Set<StatKind> = Set(StatKind.allCases),
                   downMbps: Double, upMbps: Double,
                   cpuPercent: Double,
                   memPercent: Double,
                   diskPercent: Double,
                   online: Bool = true,
                   latencyMs: Double? = nil) -> [TitleSegment] {
    let shown = pinned.intersection(enabled)
    var segments: [TitleSegment] = []
    if shown.contains(.network) {
        segments.append(TitleSegment(symbol: "",
                                     text: "↓ \(fmtMbps(downMbps)) ↑ \(fmtMbps(upMbps)) Mbps"))
    }
    if shown.contains(.cpu) {
        segments.append(TitleSegment(symbol: "cpu", text: fmtPercent(cpuPercent)))
    }
    if shown.contains(.memory) {
        segments.append(TitleSegment(symbol: "memorychip", text: fmtPercent(memPercent)))
    }
    if shown.contains(.disk) {
        segments.append(TitleSegment(symbol: "internaldrive", text: fmtPercent(diskPercent)))
    }
    if shown.contains(.internet) {
        segments.append(TitleSegment(symbol: "wifi",
                                     text: online ? fmtLatency(latencyMs) : "offline"))
    }
    if segments.isEmpty {
        segments.append(TitleSegment(symbol: "chart.bar.fill", text: ""))
    }
    return segments
}

/// Plain-text rendering of the segments (for the state file / QA).
func titlePlainText(_ segments: [TitleSegment]) -> String {
    segments.map { segment in
        switch segment.symbol {
        case "cpu": return "CPU " + segment.text
        case "memorychip": return "RAM " + segment.text
        case "internaldrive": return "DISK " + segment.text
        case "wifi": return "PING " + segment.text
        case "chart.bar.fill": return "Neticle"
        default: return segment.text
        }
    }.joined(separator: " · ")
}
