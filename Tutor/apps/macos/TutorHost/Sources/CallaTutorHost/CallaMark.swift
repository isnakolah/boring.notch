import AppKit

/// Calla's pointer, as a menu bar image.
///
/// The same outline the overlay draws and the same one in the app icon, so the
/// thing in the menu bar and the thing moving over the lesson are recognisably
/// one product. Drawn as a template image, which is what lets macOS tint it for
/// a light or dark menu bar instead of pasting a blue glyph onto both.
enum CallaMark {
    /// The geometry from assets/calla-cursor.svg, in its 512 view box.
    private static let outline: [CGPoint] = [
        CGPoint(x: 100, y: 90),
        CGPoint(x: 418, y: 218),
        CGPoint(x: 300, y: 298),
        CGPoint(x: 240, y: 418),
    ]
    private static let viewBox: CGFloat = 512
    private static let join: CGFloat = 62

    static let menuBar: NSImage = image(edge: 16)

    /// A tinted, non-template mark.
    ///
    /// Template images are recoloured by the system to match the menu bar, which
    /// is what you want for a plain icon and exactly wrong here: the colour is
    /// the status. Green ready, blue teaching, orange needs something, grey
    /// paused — legible without opening the menu at all.
    static func image(edge: CGFloat, tint: NSColor) -> NSImage {
        let base = image(edge: edge)
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    static func image(edge: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            let scale = min(rect.width, rect.height) / viewBox
            let path = NSBezierPath()
            // The artwork is authored with a top-left origin; this context has a
            // bottom-left one, so every y is mirrored.
            for (index, point) in outline.enumerated() {
                let mapped = NSPoint(x: rect.minX + point.x * scale,
                                     y: rect.minY + (viewBox - point.y) * scale)
                if index == 0 { path.move(to: mapped) } else { path.line(to: mapped) }
            }
            path.close()
            // Stroking the fill with a round join is what rounds the corners,
            // including the concave notch.
            path.lineJoinStyle = .round
            path.lineWidth = join * scale
            NSColor.black.setFill()
            NSColor.black.setStroke()
            path.fill()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
