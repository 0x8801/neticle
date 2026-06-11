import AppKit

// Generates the Neticle brand icon: dark rounded plate with ascending
// stat bars and a trend dot. Run: swift scripts/make_icon.swift
// (then build.sh copies Resources/AppIcon.icns into the app)

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Big Sur-style margin: artwork inset ~10% inside the canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1),
])!.draw(in: platePath, angle: -90)

// Three ascending rounded bars — the "stats" mark.
let barWidth: CGFloat = 128
let gap: CGFloat = 62
let baseY: CGFloat = 270
let firstX = (canvas - 3 * barWidth - 2 * gap) / 2
let bars: [(height: CGFloat, color: NSColor)] = [
    (190, NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.49, alpha: 1)),  // green
    (310, NSColor(calibratedRed: 0.27, green: 0.78, blue: 0.86, alpha: 1)),  // teal
    (450, NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.26, alpha: 1)),  // orange
]
for (index, bar) in bars.enumerated() {
    let rect = NSRect(x: firstX + CGFloat(index) * (barWidth + gap),
                      y: baseY, width: barWidth, height: bar.height)
    bar.color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: barWidth / 2.6, yRadius: barWidth / 2.6).fill()
}

// Trend dot floating above the tallest bar.
let dot = NSRect(x: firstX + 2 * (barWidth + gap) + barWidth / 2 - 46,
                 y: baseY + 450 + 64, width: 92, height: 92)
NSColor.white.withAlphaComponent(0.92).setFill()
NSBezierPath(ovalIn: dot).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}
let master = "/tmp/neticle-icon-1024.png"
try! png.write(to: URL(fileURLWithPath: master))
print("master written to \(master)")
