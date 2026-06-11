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
