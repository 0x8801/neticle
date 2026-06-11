import CoreGraphics
import Foundation

// QA helper: proves Neticle's status item exists on screen by finding its
// window in the window server list (owner names + bounds are readable
// without the Screen Recording permission). Status items live at layer 25.
// Run: swift qa/check_window.swift

guard let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
    print("ERROR: CGWindowListCopyWindowInfo returned nil")
    exit(2)
}

var found = 0
for window in raw {
    guard let owner = window["kCGWindowOwnerName"] as? String, owner == "Neticle" else { continue }
    found += 1
    let layer = window["kCGWindowLayer"] as? Int ?? -1
    let onscreen = (window["kCGWindowIsOnscreen"] as? Bool) ?? false
    let bounds = window["kCGWindowBounds"] as? [String: Any] ?? [:]
    func num(_ key: String) -> Double { (bounds[key] as? Double) ?? -1 }
    print("Neticle window: layer=\(layer) onscreen=\(onscreen) "
        + "x=\(Int(num("X"))) y=\(Int(num("Y"))) w=\(Int(num("Width"))) h=\(Int(num("Height")))")
}

let owners = Set(raw.compactMap { $0["kCGWindowOwnerName"] as? String })
let menubarish = raw.filter { ($0["kCGWindowLayer"] as? Int ?? 0) == 25 }
    .compactMap { $0["kCGWindowOwnerName"] as? String }
print("windows=\(raw.count) owners=\(owners.count) layer25(status items)=\(menubarish.sorted())")
let display = CGDisplayBounds(CGMainDisplayID())
print("main display: \(Int(display.width))x\(Int(display.height))")
exit(found > 0 ? 0 : 1)
