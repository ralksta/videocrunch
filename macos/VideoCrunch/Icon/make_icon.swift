import AppKit
// The VideoCrunch app icon, drawn rather than painted so it can be changed and
// rebuilt: build_icon.sh runs this and turns the PNG into AppIcon.icns.
//
// Drawn on the macOS icon grid — 1024 canvas, 824 rounded tile with a
// transparent margin and drop shadow. macOS 26+ recognises that shape and
// renders it as is; a full-bleed opaque square would get a second tile around
// it. Usage: swift make_icon.swift <out.png>
let out = CommandLine.arguments[1]
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Tile
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
let drop = NSShadow()
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.shadowBlurRadius = 28
drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
NSGraphicsContext.saveGraphicsState()
drop.set()
rgb(0x2A2F8F).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [rgb(0x4F7BFF), rgb(0x3B3FD1), rgb(0x24206E)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
// soft light from the top
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 980), radius: 0, toCenter: NSPoint(x: 512, y: 980), radius: 620,
          options: [])
NSGraphicsContext.restoreGraphicsState()

// Film frame: sprocket holes top and bottom, picture window in the middle,
// all cut out so the tile shows through. Narrower than tall — squeezed.
let frame = NSRect(x: 512 - 150, y: 512 - 168, width: 300, height: 336)
let glyph = NSBezierPath(roundedRect: frame, xRadius: 44, yRadius: 44)
for row in [frame.maxY - 30 - 40, frame.minY + 30] {
    for cx in [512 - 84, 512, 512 + 84] as [CGFloat] {
        glyph.append(NSBezierPath(roundedRect: NSRect(x: cx - 24, y: row, width: 48, height: 40),
                                  xRadius: 11, yRadius: 11))
    }
}
glyph.append(NSBezierPath(roundedRect: NSRect(x: frame.minX + 34, y: frame.minY + 94,
                                              width: frame.width - 68, height: frame.height - 188),
                          xRadius: 22, yRadius: 22))
glyph.windingRule = .evenOdd
let lift = NSShadow()
lift.shadowOffset = NSSize(width: 0, height: -10)
lift.shadowBlurRadius = 24
lift.shadowColor = rgb(0x0B0A3A, 0.45)
NSGraphicsContext.saveGraphicsState()
lift.set()
NSColor.white.setFill()
glyph.fill()
NSGraphicsContext.restoreGraphicsState()

// Chevrons squeezing it from both sides
func chevron(tipX: CGFloat, dir: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: tipX - dir * 70, y: 512 + 92))
    p.line(to: NSPoint(x: tipX, y: 512))
    p.line(to: NSPoint(x: tipX - dir * 70, y: 512 - 92))
    p.lineWidth = 46
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    return p
}
rgb(0x7DF0FF).setStroke()
chevron(tipX: frame.minX - 40, dir: 1).stroke()
chevron(tipX: frame.maxX + 40, dir: -1).stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
