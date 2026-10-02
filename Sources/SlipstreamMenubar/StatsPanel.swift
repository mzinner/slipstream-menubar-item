import AppKit
import Charts
import SlipstreamMenubarCore
import SwiftUI

/// The floating window with the serving and system charts.
@MainActor
final class StatsPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let server: ServerController
    private let stats: StatsModel
    private let onVisibilityChange: (Bool) -> Void

    init(server: ServerController, stats: StatsModel, onVisibilityChange: @escaping (Bool) -> Void) {
        self.server = server
        self.stats = stats
        self.onVisibilityChange = onVisibilityChange
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.title = "Slipstream"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentMinSize = NSSize(width: 380, height: 360)
            panel.contentView = NSHostingView(rootView: StatsView(server: server, stats: stats))
            panel.setFrameAutosaveName("SlipstreamStatsPanel")
            if panel.frame.origin == .zero { panel.center() }
            panel.delegate = self
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        onVisibilityChange(true)
    }

    func toggle() {
        if isVisible { panel?.close() } else { show() }
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange(false)
    }
}

// MARK: - Views

struct StatsView: View {
    @ObservedObject var server: ServerController
    @ObservedObject var stats: StatsModel

    var body: some View {
        ScrollView {
            StatsContent(server: server, stats: stats)
        }
        .frame(minWidth: 380)
    }
}

/// The panel's sections, without the scroll view (which ImageRenderer cannot draw).
struct StatsContent: View {
    @ObservedObject var server: ServerController
    @ObservedObject var stats: StatsModel

    var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ServerHeader(server: server, stats: stats)
                if server.status == .running, let engine = stats.engine {
                    ServingSections(stats: stats, engine: engine)
                } else if server.status == .running, let error = stats.metricsError {
                    Notice(text: error)
                } else if server.status == .running {
                    Notice(text: "Waiting for metrics…")
                }
                SystemSections(stats: stats)
            }
            .padding(16)
    }
}

private struct ServerHeader: View {
    @ObservedObject var server: ServerController
    @ObservedObject var stats: StatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: server.status.color)).frame(width: 10, height: 10)
                Text(server.status.title).font(.headline)
                if server.external && server.status.isActive {
                    Text("started elsewhere").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if server.status.isActive {
                    Button("Stop") { server.stop() }.disabled(server.status == .stopping)
                } else {
                    Button("Start") { try? server.start() }
                }
            }
            if let model = server.model {
                Text((model as NSString).lastPathComponent).font(.subheadline)
            }
            HStack(spacing: 12) {
                if server.status.isActive {
                    Text(verbatim: "127.0.0.1:\(server.port)")
                }
                if let maximum = stats.maximumContextTokens {
                    Text(verbatim: "context limit \(Format.contextTokens(maximum))")
                }
                if let pid = server.pid {
                    Text(verbatim: "pid \(pid)")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if case .failed(let message) = server.status {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

private struct ServingSections: View {
    @ObservedObject var stats: StatsModel
    let engine: EngineSample

    var body: some View {
        Section(title: "Throughput") {
            Figures([
                ("Output", Format.rate(stats.rates?.outputTokensPerSecond)),
                ("Avg while busy", Format.rate(stats.averageOutputWhileBusy)),
                ("Prompt", Format.rate(stats.rates?.promptTokensPerSecond)),
            ])
            SeriesChart(series: [("Output tok/s", .blue, stats.outputTokensPerSecond)],
                        valueLabel: { Format.tokens($0) }, minimumTop: 50)
            SeriesChart(series: [("Prompt tok/s", .teal, stats.promptTokensPerSecond)],
                        valueLabel: { Format.tokens($0) }, height: 70, minimumTop: 500)
        }

        Section(title: "Context & KV cache") {
            let block = Double(stats.kvBlockTokens)
            Figures([
                ("In use", Format.tokens(engine.kvPagesActive * block)),
                ("Cached", Format.tokens(engine.kvPagesCached * block)),
                ("Free", Format.tokens(engine.kvPagesFree * block)),
                ("Capacity", Format.tokens(engine.kvPagesTotal * block)),
            ])
            SeriesChart(series: [("In use", .orange, stats.kvActiveTokens),
                                 ("Cached", .purple, stats.kvCachedTokens)],
                        valueLabel: { Format.tokens($0) }, stacked: true, minimumTop: 4000)
        }

        Section(title: "Requests") {
            Figures([
                ("Active", String(format: "%.0f", engine.activeRequests)),
                ("Queued", String(format: "%.0f", engine.queued)),
                ("Completed", String(format: "%.0f", engine.requestsCompleted)),
                ("Failed", String(format: "%.0f", engine.requestsFailed)),
            ])
            SeriesChart(series: [("Active", .green, stats.activeRequests),
                                 ("Queued", .red, stats.queuedRequests)],
                        valueLabel: { String(format: "%.0f", $0) }, height: 60, minimumTop: 4)
            Figures([
                ("TTFT p50 / p95", "\(Format.milliseconds(engine.ttftP50Milliseconds)) / \(Format.milliseconds(engine.ttftP95Milliseconds))"),
                ("ITL p50 / p95", "\(Format.milliseconds(engine.itlP50Milliseconds)) / \(Format.milliseconds(engine.itlP95Milliseconds))"),
            ])
            Figures([
                ("Draft acceptance", Format.percent(engine.draftAcceptance)),
                ("Cache hit rate", Format.percent(engine.cacheHitRate)),
            ])
        }

        Section(title: "Engine memory") {
            Figures([
                ("Used", Format.gigabytes(engine.memoryUsedBytes)),
                ("Limit", Format.gigabytes(engine.memoryLimitBytes)),
                ("Headroom", Format.gigabytes(engine.memoryHeadroomBytes)),
                ("Pressure", engine.memoryPressure ?? "–"),
            ])
            SeriesChart(series: [("Used", .indigo, stats.engineMemoryUsed)],
                        valueLabel: { Format.gigabytes($0) }, height: 60,
                        yMaximum: engine.memoryLimitBytes)
        }
    }
}

private struct SystemSections: View {
    @ObservedObject var stats: StatsModel

    var body: some View {
        Section(title: "System") {
            if let system = stats.system {
                Figures([
                    ("CPU", Format.percent(system.cpuUsage)),
                    ("GPU", Format.percent(system.gpuUsage)),
                    ("Pressure", system.memoryPressure),
                ])
                SeriesChart(series: [("CPU %", .blue, stats.cpuUsage), ("GPU %", .pink, stats.gpuUsage)],
                            valueLabel: { String(format: "%.0f%%", $0) }, height: 70, yMaximum: 100)
                Figures([
                    ("Memory used", "\(Format.gigabytes(system.memoryUsedBytes)) of \(Format.gigabytes(system.memoryTotalBytes))"),
                    ("Wired", Format.gigabytes(system.memoryWiredBytes)),
                    ("Swap", Format.gigabytes(system.swapUsedBytes)),
                ])
                SeriesChart(series: [("Memory", .indigo, stats.systemMemoryUsed), ("Swap", .red, stats.swapUsed)],
                            valueLabel: { Format.gigabytes($0) }, height: 70,
                            yMaximum: system.memoryTotalBytes)
            }
        }
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct Figures: View {
    let items: [(String, String)]

    init(_ items: [(String, String)]) {
        self.items = items
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    Text(items[index].0).font(.caption2).foregroundStyle(.secondary)
                    Text(items[index].1).font(.system(.callout, design: .rounded).monospacedDigit())
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct Notice: View {
    let text: String

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line (or stacked area) chart over the last five minutes.
private struct SeriesChart: View {
    let series: [(String, Color, TimeSeries)]
    let valueLabel: (Double) -> String
    var height: CGFloat = 90
    var stacked = false
    var yMaximum: Double?
    /// The smallest top for the y axis, so an idle chart still has sensible labels.
    var minimumTop: Double = 1

    /// Fits the widest label, e.g. "46.6 GB".
    static let axisLabelWidth: CGFloat = 46

    private struct Point: Identifiable {
        let series: String
        let time: Date
        let value: Double
        var id: String { "\(series)-\(time.timeIntervalSinceReferenceDate)" }
    }

    private var points: [Point] {
        series.flatMap { name, _, values in
            values.points.map { Point(series: name, time: $0.time, value: $0.value) }
        }
    }

    var body: some View {
        let now = Date()
        Chart(points) { point in
            if stacked {
                AreaMark(x: .value("Time", point.time), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
            } else {
                LineMark(x: .value("Time", point.time), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.0), range: series.map(\.1))
        .chartXScale(domain: now.addingTimeInterval(-300)...now)
        .chartYScale(domain: 0...yDomainMaximum)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute)) { _ in
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    // One fixed width for every chart, so their plot areas line up.
                    if let number = value.as(Double.self) {
                        Text(valueLabel(number))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .frame(width: Self.axisLabelWidth, alignment: .leading)
                    }
                }
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .frame(height: height)
    }

    private var yDomainMaximum: Double {
        if let yMaximum, yMaximum > 0 { return yMaximum }
        let peak: Double
        if stacked {
            // Stacked areas add up at each instant.
            var totals: [Date: Double] = [:]
            for point in points { totals[point.time, default: 0] += point.value }
            peak = totals.values.max() ?? 0
        } else {
            peak = points.map(\.value).max() ?? 0
        }
        return max(peak * 1.15, minimumTop)
    }
}
