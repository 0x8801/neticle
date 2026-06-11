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

// --- one-shot snapshot parsing + diffing ---
let snap1 = parseNettopSnapshot("""
time,,bytes_in,bytes_out,
11:56:50.309465,launchd.1,100,200,
11:56:50.309466,curl.42,5000,300,
""")
expect(snap1.count == 2, "snapshot parses rows, skips header (got \(snap1.count))")

let snap2 = parseNettopSnapshot("""
time,,bytes_in,bytes_out,
11:56:53.000000,launchd.1,150,260,
11:56:53.000001,curl.42,905000,1300,
11:56:53.000002,Spotify.7,10,20,
""")
var prevMap: [String: ProcTraffic] = [:]
for r in snap1 { prevMap[snapshotKey(r)] = r }
var curMap: [String: ProcTraffic] = [:]
for r in snap2 { curMap[snapshotKey(r)] = r }
let deltas = diffSnapshots(previous: prevMap, current: curMap)
expect(deltas.count == 2, "first-seen processes skipped in diff (got \(deltas.count))")
let curlDelta = deltas.first { $0.name == "curl" }
expect(curlDelta?.bytesIn == 900_000 && curlDelta?.bytesOut == 1000, "diff computes byte deltas")

let restarted = diffSnapshots(
    previous: ["42|x": ProcTraffic(name: "x", pid: 42, bytesIn: 9999, bytesOut: 9999)],
    current: ["42|x": ProcTraffic(name: "x", pid: 42, bytesIn: 5, bytesOut: 7)])
expect(restarted.first?.bytesIn == 0 && restarted.first?.bytesOut == 0,
       "backwards counters clamp to zero (pid reuse)")

// --- ps parsing (CPU / memory top lists) ---
let psOutput = """
  0.0  1234   1 launchd
 12.5 524288  4142 Google Chrome Helper (Renderer)
  3.2 131072   999 WindowServer
 99.9 2048  4321 yes
"""
let procs = parsePsRows(psOutput)
expect(procs.count == 4, "ps rows parsed (got \(procs.count))")
expect(procs[1].name == "Google Chrome Helper (Renderer)" && procs[1].pid == 4142,
       "ps comm with spaces survives")
expect(procs[1].rssBytes == 524_288 * 1024, "ps rss is KB → bytes")
expect(topByCPU(procs).first?.name == "yes", "topByCPU sorts by pcpu")
expect(topByMemory(procs).first?.name == "Google Chrome Helper (Renderer)", "topByMemory sorts by rss")
expect(parsePsRows("garbage line\n").isEmpty, "ps garbage rejected")

// --- du parsing (largest folders) ---
let duOutput = """
1048576\t/Users/x/Movies
2097152\t/Users/x/Library/Caches
512\t/Users/x/.hidden
4194304\t/Users/x
8192\t/Users/x/Library
524288\t/Users/x/Downloads
"""
let dirs = parseDuRows(duOutput, roots: ["/Users/x", "/Users/x/Library"])
expect(dirs.count == 3, "du roots and hidden dirs dropped (got \(dirs.count))")
expect(dirs.first?.path == "/Users/x/Library/Caches" && dirs.first?.bytes == 2_097_152 * 1024,
       "du sorted desc, KB → bytes")
expect(dirs.first?.displayName == "Caches", "du display name is last component")

// --- human formatting ---
expect(bytesHuman(512 * 1024) == "512 KB", "bytesHuman KB")
expect(bytesHuman(200 * 1_048_576) == "200 MB", "bytesHuman MB")
expect(bytesHuman(UInt64(2.5 * 1_073_741_824)) == "2.5 GB", "bytesHuman GB")
expect(bytesHuman(250 * 1_073_741_824) == "250 GB", "bytesHuman big GB drops decimals")
expect(fmtPercent(23.4) == "23%", "fmtPercent rounds")

// --- pinned menu bar title ---
let onlyNet = titleSegments(pinned: [.network], downMbps: 2.1, upMbps: 0.3,
                            cpuPercent: 50, memPercent: 60, diskPercent: 70)
expect(onlyNet == [TitleSegment(symbol: "", text: "↓ 2.1 ↑ 0.3 Mbps")],
       "network-only pin keeps classic title")
expect(titlePlainText(onlyNet) == "↓ 2.1 ↑ 0.3 Mbps", "plain text network title")

let all = titleSegments(pinned: Set(StatKind.allCases), downMbps: 1.0, upMbps: 0.5,
                        cpuPercent: 23.4, memPercent: 61.8, diskPercent: 80.9,
                        online: true, latencyMs: 23)
expect(all.count == 5, "all pins → 5 segments")
expect(titlePlainText(all) == "↓ 1.0 ↑ 0.5 Mbps · CPU 23% · RAM 62% · DISK 81% · PING 23 ms",
       "plain text all-pinned title (got \(titlePlainText(all)))")

let none = titleSegments(pinned: [], downMbps: 0, upMbps: 0,
                         cpuPercent: 0, memPercent: 0, diskPercent: 0)
expect(none == [TitleSegment(symbol: "chart.bar.fill", text: "")], "no pins → logo only")
expect(titlePlainText(none) == "Neticle", "plain text logo title")

let gated = titleSegments(pinned: [.cpu, .network], enabled: [.network],
                          downMbps: 2.0, upMbps: 0.1,
                          cpuPercent: 50, memPercent: 0, diskPercent: 0)
expect(titlePlainText(gated) == "↓ 2.0 ↑ 0.1 Mbps",
       "disabled sections can't contribute pinned segments")

let offline = titleSegments(pinned: [.internet], downMbps: 0, upMbps: 0,
                            cpuPercent: 0, memPercent: 0, diskPercent: 0,
                            online: false, latencyMs: nil)
expect(titlePlainText(offline) == "PING offline", "offline shows in pinned title")

// --- IP details parsing ---
let whoIsFixture = """
{"ip":"203.0.113.7","success":true,"city":"Nairobi","region":"Nairobi County",
 "country":"Kenya","country_code":"KE","flag":{"emoji":"🇰🇪"},
 "connection":{"asn":33771,"org":"Safaricom Ltd","isp":"Safaricom PLC"}}
""".data(using: .utf8)!
let whoIs = parseIPWhoIs(whoIsFixture)
expect(whoIs == IPDetails(ip: "203.0.113.7", city: "Nairobi", country: "Kenya",
                          countryCode: "KE", isp: "Safaricom PLC"),
       "ipwho.is fixture parses")
expect(parseIPWhoIs("{\"success\":false}".data(using: .utf8)!) == nil, "ipwho.is failure rejected")

let apiCoFixture = """
{"ip":"203.0.113.7","city":"Nairobi","region":"Nairobi","country_name":"Kenya",
 "country_code":"KE","org":"SAFARICOM"}
""".data(using: .utf8)!
let apiCo = parseIPApiCo(apiCoFixture)
expect(apiCo?.isp == "SAFARICOM" && apiCo?.country == "Kenya", "ipapi.co fixture parses")

expect(flagEmoji("KE") == "🇰🇪", "flagEmoji KE")
expect(flagEmoji("us") == "🇺🇸", "flagEmoji lowercase")
expect(flagEmoji("") == "" && flagEmoji("K1") == "", "flagEmoji invalid input")

// --- latency formatting + sparkline geometry ---
expect(fmtLatency(nil) == "—" && fmtLatency(0.4) == "<1 ms" && fmtLatency(23.4) == "23 ms",
       "fmtLatency variants")

let spark = sparklineSegments([10, 20, nil, 40, 50], in: CGSize(width: 100, height: 40))
expect(spark.lines.count == 2, "sparkline splits on offline gap (got \(spark.lines.count))")
expect(spark.offlineXs.count == 1 && spark.offlineXs[0] == 50, "offline marker at gap x")
expect(spark.lines[0].count == 2 && spark.lines[0][0].x == 0 && spark.lines[0][1].x == 25,
       "sparkline x spacing even")
expect(sparklineSegments([], in: CGSize(width: 100, height: 40)).lines.isEmpty,
       "empty history → no lines")
let flat = sparklineSegments([50, 50], in: CGSize(width: 100, height: 100))
expect(flat.lines[0][0].y == 50, "y normalized against 100 ms floor")

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
