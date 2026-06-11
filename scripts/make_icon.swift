import AppKit

// Generates Resources/AppIcon.icns: a dark rounded square with ↓/↑ arrows.
// Run: swift scripts/make_icon.swift   (then build.sh copies it into the app)

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Big Sur-style margin: icon artwork inset ~10% inside the canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1),
])!.draw(in: platePath, angle: -90)

func drawArrow(_ glyph: String, color: NSColor, centerX: CGFloat) {
    let font = NSFont.systemFont(ofSize: 430, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: glyph, attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: centerX - size.width / 2, y: (canvas - size.height) / 2))
}

drawArrow("↓", color: NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.49, alpha: 1), centerX: 392)
drawArrow("↑", color: NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.26, alpha: 1), centerX: 660)

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
