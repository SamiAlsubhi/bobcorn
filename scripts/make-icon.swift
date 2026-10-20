// Renders the app icon (a striped popcorn box with a play button) to a
// 1024px PNG. build-app.sh turns it into AppIcon.icns.
//
//   swift scripts/make-icon.swift <output.png>

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824px rounded square centred in the canvas.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.16, green: 0.13, blue: 0.20, alpha: 1).cgColor,
    NSColor(red: 0.07, green: 0.06, blue: 0.09, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// A soft spotlight behind the box.
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.95, green: 0.35, blue: 0.25, alpha: 0.45).cgColor,
    NSColor(red: 0.95, green: 0.35, blue: 0.25, alpha: 0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size * 0.55), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: size * 0.55), endRadius: 420, options: [])

// Popcorn heads above the box.
let kernel = NSColor(red: 1.0, green: 0.95, blue: 0.80, alpha: 1)
let kernelShade = NSColor(red: 0.96, green: 0.80, blue: 0.45, alpha: 1)
let puffs: [(CGFloat, CGFloat, CGFloat)] = [
    (360, 690, 78), (450, 735, 86), (548, 742, 88), (642, 700, 80),
    (405, 640, 70), (505, 668, 82), (600, 646, 74), (318, 610, 56), (690, 612, 58),
]
for (x, y, r) in puffs {
    ctx.setFillColor(kernelShade.cgColor)
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r - 8, width: r * 2, height: r * 2))
    ctx.setFillColor(kernel.cgColor)
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2 - 6))
}

// The box: a trapezoid with red and white stripes.
let topY: CGFloat = 620, bottomY: CGFloat = 215
let topL: CGFloat = 270, topR: CGFloat = 754, botL: CGFloat = 340, botR: CGFloat = 684
let box = CGMutablePath()
box.move(to: CGPoint(x: topL, y: topY))
box.addLine(to: CGPoint(x: topR, y: topY))
box.addLine(to: CGPoint(x: botR, y: bottomY))
box.addLine(to: CGPoint(x: botL, y: bottomY))
box.closeSubpath()
ctx.saveGState()
ctx.addPath(box)
ctx.clip()
let stripes = 7
for i in 0..<stripes {
    let t0 = CGFloat(i) / CGFloat(stripes), t1 = CGFloat(i + 1) / CGFloat(stripes)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: topL + (topR - topL) * t0, y: topY))
    p.addLine(to: CGPoint(x: topL + (topR - topL) * t1, y: topY))
    p.addLine(to: CGPoint(x: botL + (botR - botL) * t1, y: bottomY))
    p.addLine(to: CGPoint(x: botL + (botR - botL) * t0, y: bottomY))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(i % 2 == 0
        ? NSColor(red: 0.90, green: 0.20, blue: 0.18, alpha: 1).cgColor
        : NSColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1).cgColor)
    ctx.fillPath()
}
// Shade the lower part of the box for depth.
let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.28).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: topY), end: CGPoint(x: 0, y: bottomY), options: [])
ctx.restoreGState()

// Rim of the box.
ctx.setFillColor(NSColor(red: 0.80, green: 0.15, blue: 0.14, alpha: 1).cgColor)
ctx.fill(CGRect(x: topL - 14, y: topY - 6, width: topR - topL + 28, height: 34))

// Play button on the front.
let center = CGPoint(x: size / 2, y: 410)
ctx.setFillColor(NSColor(red: 0.10, green: 0.08, blue: 0.12, alpha: 0.92).cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224))
let tri = CGMutablePath()
tri.move(to: CGPoint(x: center.x - 38, y: center.y + 58))
tri.addLine(to: CGPoint(x: center.x + 66, y: center.y))
tri.addLine(to: CGPoint(x: center.x - 38, y: center.y - 58))
tri.closeSubpath()
ctx.addPath(tri)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()

ctx.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("could not encode PNG") }
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
