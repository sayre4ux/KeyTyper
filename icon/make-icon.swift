// Draws the TypeThru app icon into an .iconset. Run through icon/make-icon.sh.
import AppKit

let output = CommandLine.arguments[1]

/// Fills the outline of a stroked path with a gradient.
func strokeGradient(_ path: NSBezierPath, width: CGFloat, _ gradient: NSGradient, angle: CGFloat, in context: CGContext) {
    let outline = path.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    context.saveGState()
    context.addPath(outline)
    context.clip()
    gradient.draw(in: path.bounds.insetBy(dx: -width, dy: -width), angle: angle)
    context.restoreGState()
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let s = CGFloat(size) / 1024
    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.45)
    drop.shadowOffset = NSSize(width: 0, height: -12 * s)
    drop.shadowBlurRadius = 28 * s
    NSGraphicsContext.saveGraphicsState()
    drop.set()
    NSColor(white: 0.06, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Graphite body, lighter at the top.
    NSGradient(starting: NSColor(red: 0.13, green: 0.14, blue: 0.19, alpha: 1),
               ending: NSColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1))!.draw(in: tile, angle: -90)
    // Light leaking through the gap in the barrier.
    let gap = NSPoint(x: 512 * s, y: 512 * s)
    NSGradient(colors: [Brand.cyan.withAlphaComponent(0.55), Brand.violet.withAlphaComponent(0.22), .clear])!
        .draw(fromCenter: gap, radius: 0, toCenter: gap, radius: 380 * s, options: [])

    let art = NSRect(x: 196 * s, y: 196 * s, width: 632 * s, height: 632 * s)
    let keys = Brand.keystrokes(in: art)
    keys.lineWidth = 46 * s
    NSColor.white.withAlphaComponent(0.55).setStroke()
    keys.stroke()

    // The barrier: a frosted glass bar split by the gap.
    let barrier = Brand.barrier(in: art)
    strokeGradient(barrier, width: 74 * s,
                   NSGradient(starting: NSColor.white.withAlphaComponent(0.42), ending: NSColor.white.withAlphaComponent(0.12))!,
                   angle: -90, in: context)
    let rim = barrier.copy() as! NSBezierPath
    rim.lineWidth = 74 * s
    let rimOutline = NSBezierPath(cgPath: rim.cgPath.copy(strokingWithWidth: 74 * s, lineCap: .round, lineJoin: .round, miterLimit: 10))
    rimOutline.lineWidth = 3 * s
    NSColor.white.withAlphaComponent(0.55).setStroke()
    rimOutline.stroke()

    // The arrow leaving the gap, with a glow.
    let arrow = Brand.arrow(in: art)
    let glow = NSShadow()
    glow.shadowColor = Brand.cyan.withAlphaComponent(0.85)
    glow.shadowBlurRadius = 40 * s
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    arrow.lineWidth = 58 * s
    Brand.cyan.withAlphaComponent(0.6).setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    strokeGradient(arrow, width: 58 * s, NSGradient(starting: Brand.cyan, ending: Brand.violet)!, angle: 0, in: context)
    let core = arrow.copy() as! NSBezierPath
    core.lineWidth = 14 * s
    NSColor.white.withAlphaComponent(0.45).setStroke()
    core.stroke()

    // Glass sheen and rim.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    shape.lineWidth = 3 * s
    NSGradient(starting: NSColor.white.withAlphaComponent(0.30), ending: NSColor.white.withAlphaComponent(0.05))!
        .draw(in: NSBezierPath(cgPath: shape.cgPath.copy(strokingWithWidth: 3 * s, lineCap: .round, lineJoin: .round, miterLimit: 10)), angle: -90)
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
