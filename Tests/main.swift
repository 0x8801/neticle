import Foundation

// Unit tests for Sources/Core.swift.
// Build & run:  swiftc -o build/neticle-tests Sources/Core.swift Tests/main.swift && ./build/neticle-tests

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS" : "FAIL") + "  " + message)
    if !condition { failures += 1 }
}

// Fixture trimmed from a real capture on this machine:
//   nettop -P -d -x -J bytes_in,bytes_out -s 1 -L 3
let fixture = """
time,,bytes_in,bytes_out,
23:31:57.690382,launchd.1,0,0,
23:31:57.690388,mDNSResponder.643,1365955260,169462654,
23:31:57.690392,Spotify.1579,485213,201259,
23:31:57.690393,Google Chrome H.4142,1336510272,7263736,
23:31:57.690397,Code Helper (Pl.26260,0,0,
23:31:57.690402,com.apple.geod.8578,35690,56971,
time,,bytes_in,bytes_out,
23:31:58.686185,launchd.1,0,0,
23:31:58.686188,Spotify.1579,52000,9000,
23:31:58.686190,Google Chrome H.4142,250000,12000,
23:31:58.686191,curl.9999,1500000,30000,
23:31:58.686192,com.apple.geod.8578,0,0,
time,,bytes_in,bytes_out,
23:31:59.686185,launchd.1,128,256,
23:31:59.686188,Spotify.1579,1000,2000,
time,,bytes_in,bytes_out,
"""

// --- Whole-stream parse: boot-totals block dropped, two delta blocks kept ---
var parser = NettopStreamParser()
let blocks = parser.feed(fixture + "\n")
expect(blocks.count == 2, "emits 2 delta blocks from 4-header capture (got \(blocks.count))")
if blocks.count == 2 {
    expect(blocks[0].first?.name == "curl", "block 1 sorted desc, biggest is curl (got \(blocks[0].first?.name ?? "nil"))")
    expect(blocks[0].first?.pid == 9999, "curl pid parsed (got \(blocks[0].first?.pid ?? -2))")
    expect(blocks[0].first?.bytesIn == 1_500_000, "curl bytesIn parsed")
    expect(blocks[0].filter { $0.total > 0 }.count == 3, "block 1 has 3 nonzero rows")
    expect(blocks[1].first?.name == "Spotify", "block 2 biggest is Spotify")
}

// --- Chunked feeding must yield identical results ---
var chunked = NettopStreamParser()
var chunkedBlocks: [[ProcTraffic]] = []
let stream = fixture + "\n"
var index = stream.startIndex
while index < stream.endIndex {
    let next = stream.index(index, offsetBy: 7, limitedBy: stream.endIndex) ?? stream.endIndex
    chunkedBlocks += chunked.feed(String(stream[index..<next]))
    index = next
}
expect(chunkedBlocks.count == blocks.count, "chunked feed emits same block count")
expect(chunkedBlocks.first?.first?.name == "curl", "chunked feed same top row")

// --- PTY-style CRLF line endings must parse identically ---
var crlfParser = NettopStreamParser()
let crlfBlocks = crlfParser.feed(fixture.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
expect(crlfBlocks.count == 2, "CRLF stream emits 2 delta blocks (got \(crlfBlocks.count))")
expect(crlfBlocks.first?.first?.name == "curl", "CRLF stream parses rows (got \(crlfBlocks.first?.first?.name ?? "nil"))")
expect(crlfBlocks.first?.first?.bytesIn == 1_500_000, "CRLF stream parses byte counts")

// --- Row parsing edge cases ---
let chrome = NettopStreamParser.parseRow("23:31:57.690393,Google Chrome H.4142,1336510272,7263736,")
expect(chrome == ProcTraffic(name: "Google Chrome H", pid: 4142, bytesIn: 1_336_510_272, bytesOut: 7_263_736),
       "row with spaces in name parses")

let geod = NettopStreamParser.parseRow("x,com.apple.geod.8578,1,2,")
expect(geod?.name == "com.apple.geod" && geod?.pid == 8578, "dotted name keeps last segment as pid")

let paren = NettopStreamParser.parseRow("x,Code Helper (Pl.26260,3,4,")
expect(paren?.name == "Code Helper (Pl" && paren?.pid == 26260, "truncated paren name parses")

let comma = NettopStreamParser.parseRow("t,weird,name.55,7,8,")
expect(comma?.name == "weird,name" && comma?.pid == 55 && comma?.bytesIn == 7 && comma?.bytesOut == 8,
       "comma inside process name survives")

let nopid = NettopStreamParser.parseRow("t,kernel_task.0,10,20,")
expect(nopid?.name == "kernel_task" && nopid?.pid == 0, "kernel_task.0 parses")

expect(NettopStreamParser.parseRow("garbage") == nil, "garbage line rejected")
expect(NettopStreamParser.parseRow("t,name.1,abc,2,") == nil, "non-numeric bytes rejected")

let nodot = NettopStreamParser.splitNamePid("name.notpid")
expect(nodot.0 == "name.notpid" && nodot.1 == -1, "non-numeric pid suffix keeps full name")

// --- Formatting ---
expect(mbps(2_000_000, over: 2) == 8.0, "2 MB over 2 s = 8 Mbps")
expect(fmtMbps(0) == "0.0", "fmtMbps(0)")
expect(fmtMbps(12.34) == "12.3", "fmtMbps(12.34)")
expect(fmtMbps(123.4) == "123", "fmtMbps(123.4) drops decimals")
expect(fmtMbps(99.96) == "100", "fmtMbps rounds up to 3 digits")
expect(statusTitle(downMbps: 1.0, upMbps: 0.3) == "↓ 1.0 ↑ 0.3 Mbps", "status title")
expect(rpad("ab", 4) == "ab  ", "rpad pads")
expect(rpad("VeryLongProcessName", 8).count == 8 && rpad("VeryLongProcessName", 8).hasSuffix("…"),
       "rpad truncates with ellipsis")
expect(lpad("1.0", 5) == "  1.0", "lpad pads")

let lines = consumerLines([ProcTraffic(name: "curl", pid: 9, bytesIn: 2_000_000, bytesOut: 250_000)], interval: 2)
expect(lines.count == 1 && lines[0].hasPrefix("1. curl") && lines[0].contains("↓  8.0") && lines[0].contains("↑  1.0"),
       "consumer line renders rates (got \(lines.first ?? "nil"))")
expect(consumerLines([], interval: 2) == ["No measurable traffic yet…"], "empty top renders placeholder")

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
