import AppKit

/// Draws the menu bar item: Slipstream's bolt, and while serving, two stacked
/// readouts (↑ prompt tok/s over ↓ output tok/s) in the menu bar's text color.
enum StatusItemImage {
    static let height: CGFloat = 22
    private static let boltSide: CGFloat = 17
    /// The bolt's box already has ~3.5 pt of empty space on its right.
    private static let gap: CGFloat = 1
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.4, weight: .semibold)
    private static let lineHeight: CGFloat = 10.2

    /// Shown in place of every value while the layout is being reviewed; nil for live values.
    static let reviewValue: Double? = 400
    /// Values above this are shown as this, which is what the column is sized for.
    static let maximumShown: Double = 400

    /// Width of the widest readout, so the item never changes size as values change.
    private static let readoutWidth: CGFloat = {
        let widest = NSAttributedString(string: "↑" + compact(maximumShown), attributes: [.font: font])
        return ceil(widest.size().width)
    }()

    /// - Parameter rates: prompt and output tokens per second; nil shows the bolt alone.
    static func make(rates: (prompt: Double, output: Double)?) -> NSImage {
        let width = rates == nil ? boltSide : boltSide + gap + readoutWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawBolt(in: NSRect(x: 0, y: (height - boltSide) / 2, width: boltSide, height: boltSide))
            if let rates {
                let x = boltSide + gap
                // Two lines centred on the bar; top line is the prompt rate.
                let top = height / 2
                let prompt = min(reviewValue ?? rates.prompt, maximumShown)
                let output = min(reviewValue ?? rates.output, maximumShown)
                drawLine("↑" + compact(prompt), right: x + readoutWidth, baseline: top + 1.4)
                drawLine("↓" + compact(output), right: x + readoutWidth, baseline: top + 1.4 - lineHeight)
            }
            return true
        }
        image.isTemplate = true  // adopts the menu bar's light or dark text color
        return image
    }

    /// The bolt from the server's web UI: `M13.5 2 5 13h6l-.5 9L19 11h-6z` in a 24-unit box.
    private static func drawBolt(in rect: NSRect) {
        let scale = rect.width / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + (24 - y) * scale)  // SVG y runs down
        }
        let path = NSBezierPath()
        path.move(to: point(13.5, 2))
        path.line(to: point(5, 13))
        path.line(to: point(11, 13))
        path.line(to: point(10.5, 22))
        path.line(to: point(19, 11))
        path.line(to: point(13, 11))
        path.close()
        path.lineWidth = 1.8 * scale * 1.15  // a touch heavier than the web's, for menu bar size
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

    /// At most four characters: "0", "9.5", "41.2", "340", "1.2K", "12K".
    static func compact(_ value: Double) -> String {
        let value = max(0, value)
        switch value {
        case ..<0.05: return "0"
        case ..<99.95: return String(format: "%.1f", value)
        case ..<999.5: return String(format: "%.0f", value)
        case ..<9_950: return String(format: "%.1fK", value / 1000)
        case ..<999_500: return String(format: "%.0fK", value / 1000)
        default: return String(format: "%.1fM", value / 1_000_000)
        }
    }
}
