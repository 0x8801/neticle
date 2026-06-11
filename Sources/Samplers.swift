import Foundation
import AppKit

// System samplers and process actions. Everything here touches the OS;
// the parsing/formatting logic lives in Core.swift where it's unit-tested.

// MARK: - Total network throughput via per-interface byte counters

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

// MARK: - Per-process network usage via periodic nettop snapshots

/// Hybrid per-process monitor:
///
/// - **Background**: a cheap one-shot snapshot (~0.02 s CPU) every `cadence`
///   seconds, diffed in-app. Catches long-running consumers at near-zero cost,
///   but misses processes shorter than two snapshots (nettop enumerates its
///   process list at launch).
/// - **Live (popover open)**: streaming `nettop -d -L 0`, which is fresh every
///   2 s and catches short-lived processes — but burns about a core while it
///   runs (its event loop is hot on busy systems), so it only runs while the
///   user is actually looking, like Activity Monitor.
final class NettopMonitor {
    let cadence: TimeInterval
    let streamInterval = 2
    private(set) var top: [ProcTraffic] = []
    /// Wall-clock seconds the current deltas cover.
    private(set) var window: Double
    /// True when nettop produces no data (e.g. under the App Sandbox, which
    /// denies its network-statistics queries).
    private(set) var unavailable = false
    var onUpdate: (() -> Void)?

    private var timer: Timer?
    private var inFlight = false
    private var previous: [String: ProcTraffic] = [:]
    private var previousAt: Date?
    private var consecutiveFailures = 0
    private let queue = DispatchQueue(label: "neticle.nettop", qos: .utility)

    private var streamProcess: Process?
    private var streamParser = NettopStreamParser()
    var isStreaming: Bool { streamProcess != nil }

    init(cadence: TimeInterval = 3) {
        self.cadence = cadence
        self.window = cadence
    }

    func start() {
        let t = Timer(timeInterval: cadence, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endLiveStream()
    }

    // MARK: Live streaming (popover open)

    func beginLiveStream() {
        guard !isStreaming, !unavailable else { return }
        streamParser = NettopStreamParser()
        let p = Process()
        // nettop block-buffers stdout when piped; `script -q /dev/null` gives
        // it a PTY so every 2 s sample flushes immediately.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null",
                       "/usr/bin/nettop", "-P", "-d", "-x", "-J", "bytes_in,bytes_out",
                       "-s", String(streamInterval), "-L", "0"]
        p.standardInput = FileHandle.nullDevice
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
            // .common keeps updates flowing while the popover has key focus.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                self?.ingestStream(text)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.streamProcess === proc else { return }
                self.streamProcess = nil           // died on its own; reopen restarts
            }
        }
        do {
            try p.run()
            streamProcess = p
        } catch {
            NSLog("Neticle: failed to start nettop stream: \(error)")
        }
    }

    func endLiveStream() {
        streamProcess?.terminate()
        streamProcess = nil
    }

    private func ingestStream(_ text: String) {
        guard isStreaming else { return }
        for block in streamParser.feed(text) {
            top = Array(block.filter { $0.total > 0 }.prefix(5))
            window = Double(streamInterval)
            onUpdate?()
        }
    }

    private func tick() {
        guard !inFlight, !unavailable else { return }
        inFlight = true
        queue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            p.arguments = ["-P", "-x", "-J", "bytes_in,bytes_out", "-s", "1", "-L", "1"]
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var rows: [ProcTraffic] = []
            if (try? p.run()) != nil {
                var data = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                p.waitUntilExit()
                rows = parseNettopSnapshot(String(data: data, encoding: .utf8) ?? "")
            }
            DispatchQueue.main.async { [weak self] in self?.ingest(rows) }
        }
    }

    private func ingest(_ rows: [ProcTraffic]) {
        inFlight = false
        guard !rows.isEmpty else {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                unavailable = true
                top = []
                stop()
                onUpdate?()
            }
            return
        }
        consecutiveFailures = 0
        let now = Date()
        var current: [String: ProcTraffic] = [:]
        for row in rows { current[snapshotKey(row)] = row }
        defer {
            previous = current
            previousAt = now
        }
        // The live stream owns `top` while it runs; snapshots only maintain
        // the diff baseline so they can take over again on popover close.
        guard !isStreaming else { return }
        guard let lastAt = previousAt, !previous.isEmpty else { return }
        let dt = now.timeIntervalSince(lastAt)
        guard dt > 0.5 else { return }
        window = dt
        top = Array(diffSnapshots(previous: previous, current: current)
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .prefix(5))
        onUpdate?()
    }
}

// MARK: - Total CPU via host_processor_info tick deltas

final class CPUSampler {
    private var prevBusy: UInt64 = 0
    private var prevTotal: UInt64 = 0
    private var primed = false

    /// Returns total CPU usage 0–100 across all cores, or nil until primed.
    func sample() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy &+= user &+ system &+ nice
            total &+= user &+ system &+ nice &+ idle
        }
        defer { prevBusy = busy; prevTotal = total; primed = true }
        guard primed, total > prevTotal else { return nil }
        let dBusy = Double(busy &- prevBusy)
        let dTotal = Double(total &- prevTotal)
        return dTotal > 0 ? min(100, 100 * dBusy / dTotal) : nil
    }
}

// MARK: - Memory via host_statistics64

struct MemoryUsage {
    let usedBytes: UInt64
    let totalBytes: UInt64
    var percent: Double { totalBytes > 0 ? 100 * Double(usedBytes) / Double(totalBytes) : 0 }
}

func sampleMemory() -> MemoryUsage? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let pageSize = UInt64(vm_kernel_page_size)
    // Roughly Activity Monitor's "Memory Used": app/active + wired + compressed.
    let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                + UInt64(stats.compressor_page_count)) * pageSize
    return MemoryUsage(usedBytes: used, totalBytes: ProcessInfo.processInfo.physicalMemory)
}

// MARK: - Disk space via statfs

struct DiskUsage {
    let usedBytes: UInt64
    let totalBytes: UInt64
    var percent: Double { totalBytes > 0 ? 100 * Double(usedBytes) / Double(totalBytes) : 0 }
}

func sampleDisk(path: String = "/") -> DiskUsage? {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return nil }
    let block = UInt64(fs.f_bsize)
    let total = UInt64(fs.f_blocks) * block
    let free = UInt64(fs.f_bavail) * block
    return DiskUsage(usedBytes: total > free ? total - free : 0, totalBytes: total)
}

// MARK: - Per-process CPU/RSS via ps

final class ProcessListSampler {
    private let queue = DispatchQueue(label: "neticle.ps", qos: .utility)
    private var running = false

    /// Asynchronously samples all processes; completion runs on the main queue.
    func sample(_ completion: @escaping ([PsProc]) -> Void) {
        guard !running else { return }
        running = true
        queue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.running = false } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-Aceo", "pcpu=,rss=,pid=,comm="]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let procs = parsePsRows(String(data: data, encoding: .utf8) ?? "")
            DispatchQueue.main.async { completion(procs) }
        }
    }
}

// MARK: - Largest-directories scan via du

final class DiskScanner {
    enum State: Equatable { case idle, scanning, done(Date) }

    private(set) var state: State = .idle
    private(set) var top: [DirSize] = []
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "neticle.du", qos: .background)
    private var process: Process?

    /// Scan roots: home one level deep plus ~/Library one level deep, so the
    /// results are actionable folders rather than one giant "Library" row.
    /// Overridable for QA via NETICLE_SCAN_PATH.
    var roots: [String] = {
        if let override = ProcessInfo.processInfo.environment["NETICLE_SCAN_PATH"] {
            return [override]
        }
        let home = NSHomeDirectory()
        return [home, home + "/Library"]
    }()

    /// Terminate an in-flight du so quitting the app doesn't orphan a
    /// minutes-long background scan.
    func cancel() {
        process?.terminate()
    }

    func rescan() {
        guard state != .scanning else { return }
        state = .scanning
        onUpdate?()
        let roots = self.roots
        queue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            p.arguments = ["-x", "-k", "-d", "1"] + roots
            p.qualityOfService = .background
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice   // permission noise is expected
            guard (try? p.run()) != nil else {
                DispatchQueue.main.async { [weak self] in
                    self?.state = .idle
                    self?.onUpdate?()
                }
                return
            }
            DispatchQueue.main.async { [weak self] in self?.process = p }
            // Read incrementally: du output can exceed the pipe buffer.
            var data = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            p.waitUntilExit()
            let rows = parseDuRows(String(data: data, encoding: .utf8) ?? "", roots: roots)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.top = rows
                self.state = .done(Date())
                self.onUpdate?()
            }
        }
    }
}

// MARK: - Process actions

enum ProcessActions {
    /// SIGTERM; returns an error message or nil on success.
    @discardableResult
    static func terminate(pid: Int32) -> String? {
        guard pid > 0 else { return "invalid pid" }
        if kill(pid, SIGTERM) == 0 { return nil }
        switch errno {
        case EPERM: return "Not permitted (other user's process)"
        case ESRCH: return "Process already exited"
        default: return String(cString: strerror(errno))
        }
    }

    /// Dumps the last 10 minutes of unified log for the pid and opens it in
    /// Console (falls back to the default .log handler).
    static func viewLogs(pid: Int32, name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let safeName = name.replacingOccurrences(of: "/", with: "-")
            let outPath = NSTemporaryDirectory() + "neticle-\(safeName)-\(pid).log"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--last", "10m", "--style", "compact",
                           "--predicate", "processID == \(pid)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var text = ""
            if (try? p.run()) != nil {
                var data = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                p.waitUntilExit()
                text = String(data: data, encoding: .utf8) ?? ""
            }
            if text.split(whereSeparator: \.isNewline).count < 2 {
                text = "No unified-log entries for \(name) (pid \(pid)) in the last 10 minutes.\n" + text
            }
            try? text.write(toFile: outPath, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                let url = URL(fileURLWithPath: outPath)
                let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
                NSWorkspace.shared.open([url], withApplicationAt: console,
                                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if error != nil { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
