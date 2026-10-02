import Foundation

/// Parses the Prometheus text exposition format that Slipstream's `/metrics` serves.
///
/// Series are keyed exactly as written, labels included, e.g.
/// `slipstream_v2_memory_pressure{state="normal"}`. Comments, blank lines and
/// lines without a numeric value are skipped; a trailing timestamp is ignored.
public enum PrometheusText {
    public static func parse(_ text: String) -> [String: Double] {
        var values: [String: Double] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Label values may contain spaces, so the series ends at the closing brace.
            let seriesEnd: String.Index
            if let brace = line.firstIndex(of: "{") {
                guard let close = line[brace...].firstIndex(of: "}") else { continue }
                seriesEnd = line.index(after: close)
            } else {
                guard let space = line.firstIndex(of: " ") else { continue }
                seriesEnd = space
            }
            let series = String(line[..<seriesEnd])
            let rest = line[seriesEnd...].split(separator: " ", omittingEmptySubsequences: true)
            guard let token = rest.first, let value = number(String(token)) else { continue }
            values[series] = value
        }
        return values
    }

    static func number(_ token: String) -> Double? {
        switch token {
        case "+Inf", "Inf": return .infinity
        case "-Inf": return -.infinity
        case "NaN": return .nan
        default: return Double(token)
        }
    }
}
