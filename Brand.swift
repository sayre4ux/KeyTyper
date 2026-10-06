import AppKit

// TypeThru mark: a T whose stem turns into an arrow, typing through to the remote side.
enum Brand {
    /// The mark in a unit square (y up), stroked with round caps and joins.
    static func glyph(in rect: NSRect) -> NSBezierPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        let path = NSBezierPath()
        path.move(to: p(0.16, 0.80)); path.line(to: p(0.68, 0.80))
        path.move(to: p(0.42, 0.80)); path.line(to: p(0.42, 0.42))
        path.curve(to: p(0.56, 0.26), controlPoint1: p(0.42, 0.33), controlPoint2: p(0.47, 0.26))
        path.line(to: p(0.84, 0.26))
        path.move(to: p(0.72, 0.39)); path.line(to: p(0.85, 0.26)); path.line(to: p(0.72, 0.13))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    /// Menu bar icon: the mark inside a key outline, as a template so macOS tints it.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let key = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25), xRadius: 4.5, yRadius: 4.5)
            key.lineWidth = 1.5
            NSColor.black.setStroke()
            key.stroke()
            let mark = glyph(in: bounds.insetBy(dx: 3.5, dy: 3.5))
            mark.lineWidth = 1.7
            mark.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TypeThru"
        return image
    }
}
