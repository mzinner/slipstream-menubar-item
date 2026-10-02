import AppKit

/// Draws the menu bar item: Slipstream's bolt, and while serving, two stacked
/// readouts in the menu bar's text color: ↓ prompt tok/s (coming in to the
/// server) over ↑ output tok/s (going out), like a network indicator.
enum StatusItemImage {
    static let height: CGFloat = 22
    /// Points per unit of the bolt's 24-unit SVG box (the size it had at 17 pt).
    private static let boltScale: CGFloat = 17.0 / 24
    /// A touch heavier than the web's 1.8, for menu bar size.
    private static let boltLineWidth: CGFloat = 1.8 * boltScale * 1.15
    /// The bolt's outline spans x 5...19 and y 2...22 of its box; the image is
    /// cropped to that plus the stroke, so no empty box margin is left over.
    private static let boltWidth: CGFloat = 14 * boltScale + boltLineWidth
    private static let boltHeight: CGFloat = 20 * boltScale + boltLineWidth
    private static let gap: CGFloat = 2
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.4, weight: .semibold)
    private static let lineHeight: CGFloat = 10.2

    /// Shown in place of every value while the layout is being reviewed; nil for live values.
    static let reviewValue: Double? = nil
    /// Values above this are shown as this, which is what the column is sized for.
    static let maximumShown: Double = 400

    /// Width of the widest readout, so the item never changes size as values change.
    private static let readoutWidth: CGFloat = {
        let widest = NSAttributedString(string: "↑" + compact(maximumShown), attributes: [.font: font])
        return ceil(widest.size().width)
    }()

    /// - Parameter rates: prompt and output tokens per second; nil shows the bolt alone.
    static func make(rates: (prompt: Double, output: Double)?) -> NSImage {
        let width = ceil(rates == nil ? boltWidth : boltWidth + gap + readoutWidth)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawBolt(originY: (height - boltHeight) / 2)
            if let rates {
                let x = boltWidth + gap
                // Two lines centred on the bar; top line is the prompt rate.
                let top = height / 2
                let prompt = min(reviewValue ?? rates.prompt, maximumShown)
                let output = min(reviewValue ?? rates.output, maximumShown)
                drawLine("↓" + compact(prompt), right: x + readoutWidth, baseline: top + 1.4)
                drawLine("↑" + compact(output), right: x + readoutWidth, baseline: top + 1.4 - lineHeight)
            }
            return true
        }
        image.isTemplate = true  // adopts the menu bar's light or dark text color
        return image
    }

    /// The bolt from the server's web UI: `M13.5 2 5 13h6l-.5 9L19 11h-6z` in a 24-unit box,
    /// drawn with its outline's left edge at x = 0 and its bottom at `originY`.
    private static func drawBolt(originY: CGFloat) {
        let inset = boltLineWidth / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            // SVG y runs down; shift so x 5 and y 22 land on the stroke's outer edge.
            NSPoint(x: inset + (x - 5) * boltScale, y: originY + inset + (22 - y) * boltScale)
        }
        let path = NSBezierPath()
        path.move(to: point(13.5, 2))
        path.line(to: point(5, 13))
        path.line(to: point(11, 13))
        path.line(to: point(10.5, 22))
        path.line(to: point(19, 11))
        path.line(to: point(13, 11))
        path.close()
        path.lineWidth = boltLineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSColor.black.setStroke()
        path.stroke()
    }

    /// Draws a right-aligned line ending at `right`.
    private static func drawLine(_ text: String, right: CGFloat, baseline: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        // draw(at:) places the line's bottom at y; lift it by the descender to sit on the baseline.
        string.draw(at: NSPoint(x: right - string.size().width, y: baseline + font.descender))
    }

    /// Whole numbers only: "0", "41", "340", "12K", "3M".
    static func compact(_ value: Double) -> String {
        let value = max(0, value)
        switch value {
        case ..<999.5: return String(format: "%.0f", value)
        case ..<999_500: return String(format: "%.0fK", value / 1000)
        default: return String(format: "%.0fM", value / 1_000_000)
        }
    }
}
