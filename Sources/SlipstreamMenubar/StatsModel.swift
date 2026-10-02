import Foundation
import SlipstreamMenubarCore

/// History for the stats panel: engine metrics while a server answers, and host
/// statistics all the time, so the charts already have data when the panel opens.
@MainActor
final class StatsModel: ObservableObject {
    /// What the charts show.
    static let window: TimeInterval = 300
    /// A hard cap above the window at the fastest (one-second) refresh.
    static let capacity = 400

    @Published private(set) var engine: EngineSample?
    @Published private(set) var rates: EngineRates?
    @Published private(set) var system: SystemSnapshot?
    @Published private(set) var maximumContextTokens: Int?
    @Published private(set) var kvBlockTokens = 32
    @Published private(set) var metricsError: String?

    @Published private(set) var outputTokensPerSecond = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var promptTokensPerSecond = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var kvActiveTokens = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var kvCachedTokens = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var activeRequests = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var queuedRequests = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var engineMemoryUsed = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var cpuUsage = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var gpuUsage = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var systemMemoryUsed = TimeSeries(capacity: capacity, window: window)
    @Published private(set) var swapUsed = TimeSeries(capacity: capacity, window: window)

    /// Seconds the plotted token rates are averaged over.
    static let rateWindow: TimeInterval = 3

    /// Stretches without engine metrics, drawn as shaded areas on the serving charts.
    @Published private(set) var gaps: [DataGap] = []
    /// Whether the last tick got metrics.
    private var receiving = false
    /// Increments at each gap, so chart lines are not drawn across it.
    private var segment = 0
    private var recentSamples: [EngineSample] = []
    private let sampler = SystemSampler()
    private let session: URLSession
    private var lastStatusFetch = Date.distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        session = URLSession(configuration: configuration)
    }

    func sample(port: Int, apiKey: String?, serverReady: Bool) async {
        let now = Date()
        let snapshot = sampler.sample(at: now)
        system = snapshot
        if let cpu = snapshot.cpuUsage { cpuUsage.append(cpu * 100, at: now) }
        if let gpu = snapshot.gpuUsage { gpuUsage.append(gpu * 100, at: now) }
        systemMemoryUsed.append(snapshot.memoryUsedBytes, at: now)
        swapUsed.append(snapshot.swapUsedBytes, at: now)

        guard serverReady, let text = await fetch("/metrics", port: port, apiKey: apiKey) else {
            noMetrics(at: now)
            return
        }
        // Stamp the counters when they arrive: the rates divide by the time between
        // readings, and the request itself can take a while when the engine is busy.
        let received = Date()
        guard let sample = EngineSample(metrics: PrometheusText.parse(text), time: received) else {
            metricsError = "The server's /metrics has no Slipstream v2 metrics"
            noMetrics(at: received)
            return
        }
        metricsError = nil
        if receiving == false, let index = gaps.indices.last, gaps[index].end == nil {
            gaps[index].end = received
        }
        receiving = true
        // Rates over a window of a few seconds: MTP drafting delivers tokens in
        // bursts, so one-second deltas swing between zero and twice the real speed.
        recentSamples.append(sample)
        recentSamples.removeAll { received.timeIntervalSince($0.time) > Self.rateWindow + 2 }
        let base = recentSamples.last { received.timeIntervalSince($0.time) >= Self.rateWindow }
            ?? recentSamples.first
        if let base, base.time < received, let rates = EngineRates.between(base, sample) {
            self.rates = rates
            outputTokensPerSecond.append(rates.outputTokensPerSecond, at: received, segment: segment)
            promptTokensPerSecond.append(rates.promptTokensPerSecond, at: received, segment: segment)
        }
        engine = sample
        let block = Double(kvBlockTokens)
        kvActiveTokens.append(sample.kvPagesActive * block, at: received, segment: segment)
        kvCachedTokens.append(sample.kvPagesCached * block, at: received, segment: segment)
        activeRequests.append(sample.activeRequests, at: received, segment: segment)
        queuedRequests.append(sample.queued, at: received, segment: segment)
        engineMemoryUsed.append(sample.memoryUsedBytes, at: received, segment: segment)
        pruneGaps(now: received)

        // /status answers slowly while the engine is busy; the limit rarely changes.
        if received.timeIntervalSince(lastStatusFetch) > 15 || maximumContextTokens == nil {
            lastStatusFetch = received
            await fetchStatus(port: port, apiKey: apiKey)
        }
    }

    /// Mean of the samples in which tokens were generated: the speed while busy.
    var averageOutputWhileBusy: Double? {
        let busy = outputTokensPerSecond.points.map(\.value).filter { $0 > 0 }
        return busy.isEmpty ? nil : busy.reduce(0, +) / Double(busy.count)
    }

    /// No metrics this tick: open a gap where the data stopped, keep the history, and
    /// forget the engine only once its last reading has left the charts' window.
    private func noMetrics(at now: Date) {
        if receiving {
            receiving = false
            segment += 1  // the next readings start a new line instead of joining the old one
            recentSamples.removeAll()  // so the first rate after the gap does not span it
            rates = nil
            gaps.append(DataGap(start: engine?.time ?? now))
        }
        pruneGaps(now: now)
        if let last = engine?.time, now.timeIntervalSince(last) > Self.window {
            clearEngine()
        }
    }

    private func pruneGaps(now: Date) {
        gaps.removeAll { gap in
            guard let end = gap.end else { return false }
            return now.timeIntervalSince(end) > Self.window
        }
    }

    private func clearEngine() {
        engine = nil
        rates = nil
        recentSamples.removeAll()
        gaps.removeAll()
        maximumContextTokens = nil
        for series in [\StatsModel.outputTokensPerSecond, \.promptTokensPerSecond, \.kvActiveTokens,
                       \.kvCachedTokens, \.activeRequests, \.queuedRequests, \.engineMemoryUsed] {
            self[keyPath: series].removeAll()
        }
    }

    private func fetchStatus(port: Int, apiKey: String?) async {
        guard let text = await fetch("/status", port: port, apiKey: apiKey),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return }
        if let maximum = object["maximum_context_tokens"] as? Int {
            maximumContextTokens = maximum
        }
        if let kv = object["kv"] as? [String: Any], let block = kv["block_tokens"] as? Int, block > 0 {
            kvBlockTokens = block
        }
    }

    private func fetch(_ path: String, port: Int, apiKey: String?) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                metricsError = "The server wants an API key: set it in Settings"
                return nil
            }
            return code == 200 ? String(decoding: data, as: UTF8.self) : nil
        } catch {
            return nil
        }
    }
}
