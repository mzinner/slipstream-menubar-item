import Foundation

/// One reading of the server's `/metrics`, reduced to what the panel shows.
public struct EngineSample: Equatable, Sendable {
    public var time: Date

    // Cumulative counters
    public var outputTokens: Double
    public var promptTokens: Double
    public var requestsSubmitted: Double
    public var requestsCompleted: Double
    public var requestsFailed: Double
    public var requestsCancelled: Double
    public var cacheHits: Double
    public var cacheMisses: Double

    // Gauges
    public var queued: Double
    public var prefilling: Double
    public var decoding: Double
    public var kvPagesTotal: Double
    public var kvPagesActive: Double
    public var kvPagesCached: Double
    public var kvPagesFree: Double
    public var memoryLimitBytes: Double
    public var memoryHeadroomBytes: Double
    public var ttftP50Milliseconds: Double?
    public var ttftP95Milliseconds: Double?
    public var itlP50Milliseconds: Double?
    public var itlP95Milliseconds: Double?
    public var draftAcceptance: Double?
    public var memoryPressure: String?

    /// The engine's memory governor: what it may use, minus what is still free.
    public var memoryUsedBytes: Double { max(0, memoryLimitBytes - memoryHeadroomBytes) }
    public var activeRequests: Double { prefilling + decoding }
    public var cacheHitRate: Double? {
        let lookups = cacheHits + cacheMisses
        return lookups > 0 ? cacheHits / lookups : nil
    }

    static let prefix = "slipstream_v2_"

    /// Returns nil when the text carries no Slipstream v2 metrics at all.
    public init?(metrics: [String: Double], time: Date) {
        func value(_ name: String) -> Double? { metrics[Self.prefix + name] }
        guard let output = value("decode_output_tokens_total") else { return nil }
        self.time = time
        outputTokens = output
        promptTokens = value("prefill_input_tokens_total") ?? 0
        requestsSubmitted = value("requests_submitted_total") ?? 0
        requestsCompleted = value("requests_completed_total") ?? 0
        requestsFailed = value("requests_failed_total") ?? 0
        requestsCancelled = value("requests_cancelled_total") ?? 0
        cacheHits = value("cache_hits_total") ?? 0
        cacheMisses = value("cache_cold_misses_total") ?? 0
        queued = value("scheduler_queued") ?? 0
        prefilling = value("scheduler_prefilling") ?? 0
        decoding = value("scheduler_decoding") ?? 0
        kvPagesTotal = value("kv_pages_total") ?? 0
        kvPagesActive = value("kv_pages_active") ?? 0
        kvPagesCached = value("kv_pages_cache") ?? 0
        kvPagesFree = value("kv_pages_free") ?? 0
        memoryLimitBytes = value("memory_limit_bytes") ?? 0
        memoryHeadroomBytes = value("memory_headroom_bytes") ?? 0
        ttftP50Milliseconds = value("ttft_p50_milliseconds")
        ttftP95Milliseconds = value("ttft_p95_milliseconds")
        itlP50Milliseconds = value("itl_p50_milliseconds")
        itlP95Milliseconds = value("itl_p95_milliseconds")
        draftAcceptance = value("draft_acceptance_ratio")
        memoryPressure = ["critical", "warning", "normal"].first {
            metrics["\(Self.prefix)memory_pressure{state=\"\($0)\"}"] == 1
        }
    }
}

/// Token rates between two samples, over wall-clock time.
///
/// The engine's own `*_tokens_per_second` gauges divide by GPU step time only,
/// which reads ~15x higher than what a client receives. Counter deltas over
/// real time match the per-request rates the server logs.
public struct EngineRates: Equatable, Sendable {
    public var outputTokensPerSecond: Double
    public var promptTokensPerSecond: Double

    /// Nil when the samples are out of order or a counter went backwards (server restart).
    public static func between(_ earlier: EngineSample, _ later: EngineSample) -> EngineRates? {
        let seconds = later.time.timeIntervalSince(earlier.time)
        guard seconds > 0,
              later.outputTokens >= earlier.outputTokens,
              later.promptTokens >= earlier.promptTokens else { return nil }
        return EngineRates(
            outputTokensPerSecond: (later.outputTokens - earlier.outputTokens) / seconds,
            promptTokensPerSecond: (later.promptTokens - earlier.promptTokens) / seconds
        )
    }
}

/// A fixed-capacity series of timestamped values for the panel's charts.
public struct TimeSeries: Sendable {
    public struct Point: Identifiable, Equatable, Sendable {
        public var time: Date
        public var value: Double
        /// Points in different segments are not joined: a new one starts after a data gap.
        public var segment: Int = 0
        public var id: Date { time }
    }

    public let capacity: Int
    /// Points older than this, relative to the newest, are dropped.
    public let window: TimeInterval
    public private(set) var points: [Point] = []

    /// `capacity` is a hard cap; `window` is what is kept at any sampling rate.
    public init(capacity: Int, window: TimeInterval = .infinity) {
        self.capacity = capacity
        self.window = window
    }

    public mutating func append(_ value: Double, at time: Date, segment: Int = 0) {
        points.append(Point(time: time, value: value, segment: segment))
        // Keep the newest point older than the window, so a chart's line can
        // still enter from the left edge.
        let cutoff = time.addingTimeInterval(-window)
        if let firstInside = points.firstIndex(where: { $0.time >= cutoff }), firstInside > 1 {
            points.removeFirst(firstInside - 1)
        }
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    /// The points to draw for a window ending at `end`, plus the one just before it.
    public func points(within window: TimeInterval, endingAt end: Date) -> [Point] {
        let start = end.addingTimeInterval(-window)
        guard let firstInside = points.firstIndex(where: { $0.time >= start }) else {
            return points.last.map { [$0] } ?? []
        }
        return Array(points[max(0, firstInside - 1)...])
    }

    public mutating func removeAll() {
        points.removeAll()
    }

    public var last: Double? { points.last?.value }
    public var maximum: Double? { points.map(\.value).max() }
}

/// A stretch of time in which no engine metrics arrived; `end` is nil while it lasts.
public struct DataGap: Equatable, Sendable {
    public var start: Date
    public var end: Date?

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    /// The gap's extent clipped to a chart window, or nil when it lies outside it.
    public func clipped(to window: ClosedRange<Date>) -> ClosedRange<Date>? {
        let lower = max(start, window.lowerBound)
        let upper = min(end ?? window.upperBound, window.upperBound)
        return lower < upper ? lower...upper : nil
    }
}
