import AppKit
import SwiftUI

// TypeThru mark: keystrokes (dashes) pass through a gap in a barrier and leave as an arrow.
enum Brand {
    static let cyan = NSColor(red: 0.36, green: 0.88, blue: 1.00, alpha: 1)
    static let violet = NSColor(red: 0.55, green: 0.38, blue: 1.00, alpha: 1)
    static let accent = Color(red: 0.42, green: 0.58, blue: 1.00)

    private static func point(_ rect: NSRect, _ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    private static func rounded(_ path: NSBezierPath) -> NSBezierPath {
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    /// The barrier: a vertical bar with a gap in the middle, in a unit square (y up).
    static func barrier(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(rect, 0.50, 0.92)); path.line(to: point(rect, 0.50, 0.66))
        path.move(to: point(rect, 0.50, 0.34)); path.line(to: point(rect, 0.50, 0.08))
        return rounded(path)
    }

    /// Keystrokes before the barrier.
    static func keystrokes(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(rect, 0.04, 0.50)); path.line(to: point(rect, 0.12, 0.50))
        path.move(to: point(rect, 0.24, 0.50)); path.line(to: point(rect, 0.32, 0.50))
        return rounded(path)
    }

    /// The arrow through the gap and out the other side.
    static func arrow(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(rect, 0.44, 0.50)); path.line(to: point(rect, 0.94, 0.50))
        path.move(to: point(rect, 0.78, 0.65)); path.line(to: point(rect, 0.95, 0.50)); path.line(to: point(rect, 0.78, 0.35))
        return rounded(path)
    }

    /// Menu bar icon, as a template so macOS tints it for light and dark menu bars.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { bounds in
            let rect = bounds.insetBy(dx: 1.5, dy: 1)
            NSColor.black.setStroke()
            for path in [barrier(in: rect), keystrokes(in: rect), arrow(in: rect)] {
                path.lineWidth = 1.8
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TypeThru"
        return image
    }
}
