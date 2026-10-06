// Draws the TypeThru app icon into an .iconset. Run through icon/make-icon.sh.
import AppKit

let output = CommandLine.arguments[1]

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(red: 0.20, green: 0.24, blue: 0.80, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.83, blue: 0.93, alpha: 1),
                        NSColor(red: 0.27, green: 0.45, blue: 0.98, alpha: 1),
                        NSColor(red: 0.36, green: 0.22, blue: 0.86, alpha: 1)])!
        .draw(in: tile, angle: -60)
    // Glass sheen across the top half.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.30), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    // Frosted keycap.
    let key = NSRect(x: 252 * s, y: 236 * s, width: 520 * s, height: 520 * s)
    let keyShape = NSBezierPath(roundedRect: key, xRadius: 120 * s, yRadius: 120 * s)
    let keyShadow = NSShadow()
    keyShadow.shadowColor = NSColor(red: 0.08, green: 0.05, blue: 0.35, alpha: 0.35)
    keyShadow.shadowOffset = NSSize(width: 0, height: -18 * s)
    keyShadow.shadowBlurRadius = 40 * s
    NSGraphicsContext.saveGraphicsState()
    keyShadow.set()
    NSColor.white.withAlphaComponent(0.20).setFill()
    keyShape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.34), ending: NSColor.white.withAlphaComponent(0.08))!
        .draw(in: keyShape, angle: -90)
    keyShape.lineWidth = 5 * s
    NSColor.white.withAlphaComponent(0.65).setStroke()
    keyShape.stroke()

    let mark = Brand.glyph(in: key.insetBy(dx: 70 * s, dy: 70 * s))
    mark.lineWidth = 58 * s
    let markShadow = NSShadow()
    markShadow.shadowColor = NSColor(red: 0.08, green: 0.05, blue: 0.35, alpha: 0.30)
    markShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    markShadow.shadowBlurRadius = 12 * s
    markShadow.set()
    NSColor.white.setStroke()
    mark.stroke()
    NSGraphicsContext.restoreGraphicsState()

    shape.lineWidth = 3 * s
    NSColor.white.withAlphaComponent(0.35).setStroke()
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * scale).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
