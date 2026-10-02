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
    /// Set once the panel has been sized for all cards, or the user resized it or
    /// switched views; until then it grows to fit its cards.
    static let sizedKey = "statsPanelUserSized"

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
            panel.contentView = NSHostingView(rootView: StatsView(server: server, stats: stats) { [weak self] height in
                self?.fit(contentHeight: height)
            })
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

    func windowWillStartLiveResize(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.sizedKey)
    }

    /// Until the user sizes the panel, make it tall enough for all cards (as far as
    /// the screen allows), keeping its top edge where it is. It only grows: the cards
    /// appear one after another at launch, and the serving ones go away when the
    /// server stops, which should not shrink the window under the user.
    private func fit(contentHeight: CGFloat) {
        guard !UserDefaults.standard.bool(forKey: Self.sizedKey), let panel,
              let screen = panel.screen ?? NSScreen.main else { return }
        // Once the serving cards are in, this is the full first-launch layout: size
        // for it, then leave the panel alone (switching views must not resize it).
        defer {
            if stats.engine != nil { UserDefaults.standard.set(true, forKey: Self.sizedKey) }
        }
        let visible = screen.visibleFrame
        let chrome = panel.frame.height - panel.contentLayoutRect.height
        let height = min(ceil(contentHeight + chrome), visible.height)
        guard height > panel.frame.height + 1 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - height }
        panel.setFrame(frame, display: true)
    }
}

// MARK: - Views

struct StatsView: View {
    @ObservedObject var server: ServerController
    @ObservedObject var stats: StatsModel

    /// Same as the content's side padding.
    static let edgeMargin: CGFloat = 16
    /// How far up the bottom fade reaches while there is more to scroll to.
    static let fadeHeight: CGFloat = 40

    @State private var moreBelow = false
    /// Reports the content's height, so the panel can be sized to fit it.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        ScrollView {
            StatsContent(server: server, stats: stats)
                .padding(.bottom, Self.edgeMargin)
                // Reports the initial height too, unlike the scroll geometry callback.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    onContentHeight(height)
                }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // The visible rect is in content coordinates, so title bar and other insets
            // do not count as content that is still to come.
            geometry.visibleRect.maxY < geometry.contentSize.height - 1
        } action: { _, hasMore in
            moreBelow = hasMore
        }

        // While content continues below the window edge, fade it out so the cut-off
        // card hints that the panel scrolls; at the end the last card shows in full.
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: moreBelow ? Self.fadeHeight : 0)
            }
        }
        .animation(.easeOut(duration: 0.2), value: moreBelow)
        .frame(minWidth: 380)
    }
}

/// Compact view: shorter charts, tighter cards, no chart legends.
private struct CompactStatsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactStats: Bool {
        get { self[CompactStatsKey.self] }
        set { self[CompactStatsKey.self] = newValue }
    }
}

/// The panel's sections, without the scroll view (which ImageRenderer cannot draw).
struct StatsContent: View {
    @ObservedObject var server: ServerController
    @ObservedObject var stats: StatsModel
    @AppStorage("compactStatsPanel") private var compact = true  // compact until chosen otherwise

    var body: some View {
            VStack(alignment: .leading, spacing: compact ? 8 : 14) {
                ServerHeader(server: server, stats: stats)
                // Kept through interruptions: the charts shade the stretch without data.
                if let engine = stats.engine {
                    if let error = stats.metricsError, server.status == .running {
                        Notice(text: error)
                    }
                    ServingSections(stats: stats, engine: engine)
                } else if server.status == .running, let error = stats.metricsError {
                    Notice(text: error)
                } else if server.status == .running {
                    Notice(text: "Waiting for metrics…")
                }
                SystemSections(stats: stats)
            }
            .padding(.horizontal, 16)
            .padding(.top, compact ? 10 : 16)
            .environment(\.compactStats, compact)
    }
}

private struct ServerHeader: View {
    @ObservedObject var server: ServerController
    @ObservedObject var stats: StatsModel
    @AppStorage("compactStatsPanel") private var compact = true  // compact until chosen otherwise

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: server.status.color)).frame(width: 10, height: 10)
                Text(server.status.title).font(.headline)
                if server.external && server.status.isActive {
                    Text("started elsewhere").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    // Switching views is the user's call on size: no more automatic fitting.
                    UserDefaults.standard.set(true, forKey: StatsPanelController.sizedKey)
                    withAnimation(.easeInOut(duration: 0.2)) { compact.toggle() }
                } label: {
                    Image(systemName: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .help(compact ? "Show the full view" : "Show a compact view")
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
                    if server.listensOnNetwork {
                        Label {
                            Text(verbatim: "network · port \(server.port)")
                        } icon: {
                            Image(systemName: "network")
                        }
                    } else {
                        Text(verbatim: "127.0.0.1:\(server.port)")
                    }
                }
                if let maximum = stats.maximumContextTokens {
                    Text(verbatim: "context limit \(Format.contextTokens(maximum))")
                }
                if let pid = server.pid {
                    Text(verbatim: "pid \(pid)")
                }
                if let running = server.runningVersion, server.status.isActive {
                    Text(verbatim: "Slipstream \(running)")
                } else if let installation = server.installation {
                    Text(verbatim: installation.displayName)
                } else {
                    Text("not installed")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if case .failed(let message) = server.status {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let installed = server.pendingUpdate, let running = server.runningVersion {
                // After an update the running server keeps its version until it restarts.
                let action = ReleasePackages.isOlder(running, installed) ? "update" : "switch"
                Label("Slipstream \(installed) is installed; this server runs \(running). "
                      + "Stop and start it to \(action).", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if server.missingMTPDraftHead && server.status.isActive {
                Label("No MTP draft head next to the model: decoding runs one token per step, much slower. "
                      + "Download the model again from the menu to add it, or see the server log.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if case .preparing(let parts) = server.status {
                // First start of a GGUF model: the converter writes <model>/prepared/.
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(min(parts, LogProgress.preparationParts)),
                                 total: Double(LogProgress.preparationParts))
                    HStack {
                        Text("Preparing the model for its first start: \(parts) of "
                             + "\(LogProgress.preparationParts) parts")
                        Spacer()
                        Text(server.preparationSecondsLeft.map { TransferEstimator.describe($0) + " left" }
                             ?? "estimating…")
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct ServingSections: View {
    @ObservedObject var stats: StatsModel
    let engine: EngineSample

    var body: some View {
        Section(title: "Throughput") {
            let outputColor = Color.blue
            let promptColor = Color.teal
            Figures([
                ("Output", Format.rate(stats.rates?.outputTokensPerSecond)),
                ("Avg while busy", Format.rate(stats.averageOutputWhileBusy)),
                ("Prompt", Format.rate(stats.rates?.promptTokensPerSecond)),
            ], colors: ["Output": outputColor, "Prompt": promptColor])
            SeriesChart(gaps: stats.gaps, series: [("Output tok/s", outputColor, stats.outputTokensPerSecond)],
                        valueLabel: { Format.tokens($0) }, minimumTop: 50)
            SeriesChart(gaps: stats.gaps, series: [("Prompt tok/s", promptColor, stats.promptTokensPerSecond)],
                        valueLabel: { Format.tokens($0) }, height: 70, minimumTop: 500)
                .padding(.top, 6)  // keeps its top axis label clear of the chart above
        }

        Section(title: "Context & KV cache") {
            let block = Double(stats.kvBlockTokens)
            Figures([
                ("In use", Format.tokens(engine.kvPagesActive * block)),
                ("Cached", Format.tokens(engine.kvPagesCached * block)),
                ("Free", Format.tokens(engine.kvPagesFree * block)),
                ("Capacity", Format.tokens(engine.kvPagesTotal * block)),
            ], colors: ["In use": .orange, "Cached": .purple])
            SeriesChart(gaps: stats.gaps, series: [("In use", .orange, stats.kvActiveTokens),
                                 ("Cached", .purple, stats.kvCachedTokens)],
                        valueLabel: { Format.tokens($0) }, stacked: true, minimumTop: 4000)
        }

        Section(title: "Requests") {
            Figures([
                ("Active", String(format: "%.0f", engine.activeRequests)),
                ("Queued", String(format: "%.0f", engine.queued)),
                ("Completed", String(format: "%.0f", engine.requestsCompleted)),
                ("Failed", String(format: "%.0f", engine.requestsFailed)),
            ], colors: ["Active": .green, "Queued": .red])
            SeriesChart(gaps: stats.gaps, series: [("Active", .green, stats.activeRequests),
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
            ], colors: ["Used": .indigo])
            SeriesChart(gaps: stats.gaps, series: [("Used", .indigo, stats.engineMemoryUsed)],
                        valueLabel: { Format.axisGigabytes($0) }, height: 60,
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
                ], colors: ["CPU": .blue, "GPU": .pink])
                SeriesChart(series: [("CPU %", .blue, stats.cpuUsage), ("GPU %", .pink, stats.gpuUsage)],
                            valueLabel: { String(format: "%.0f%%", $0) }, height: 70, yMaximum: 100)
                Figures([
                    ("Memory used", "\(Format.gigabytes(system.memoryUsedBytes)) of \(Format.gigabytes(system.memoryTotalBytes))"),
                    ("Wired", Format.gigabytes(system.memoryWiredBytes)),
                    ("Swap", Format.gigabytes(system.swapUsedBytes)),
                ], colors: ["Memory used": .indigo, "Swap": .red])
                SeriesChart(series: [("Memory", .indigo, stats.systemMemoryUsed), ("Swap", .red, stats.swapUsed)],
                            valueLabel: { Format.axisGigabytes($0) }, height: 70,
                            yMaximum: system.memoryTotalBytes)
            }
        }
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.compactStats) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct Figures: View {
    let items: [(String, String)]
    /// A dot after the label, keyed by label, matching that value's chart line.
    let colors: [String: Color]

    @Environment(\.compactStats) private var compact

    init(_ items: [(String, String)], colors: [String: Color] = [:]) {
        self.items = items
        self.colors = colors
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(items[index].0).font(.caption2).foregroundStyle(.secondary)
                        if let color = colors[items[index].0] {
                            Circle().fill(color).frame(width: 6, height: 6)
                        }
                    }
                    Text(items[index].1)
                        .font(.system(compact ? .caption : .callout, design: .rounded).monospacedDigit())
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
    /// Stretches without data, shaded in light gray.
    var gaps: [DataGap] = []
    let series: [(String, Color, TimeSeries)]
    let valueLabel: (Double) -> String
    var height: CGFloat = 90
    var stacked = false
    var yMaximum: Double?
    /// The smallest top for the y axis, so an idle chart still has sensible labels.
    var minimumTop: Double = 1

    @Environment(\.compactStats) private var compact

    /// Fits the widest axis label ("100%", "4.0K", "47G"); values switch to K, M and G.
    static let axisLabelWidth: CGFloat = 34

    private struct Point: Identifiable {
        let series: String
        let segment: Int
        let time: Date
        let value: Double
        var id: String { "\(series)-\(time.timeIntervalSinceReferenceDate)" }
        /// Lines join only within one series' segment, so they break at data gaps.
        var line: String { "\(series)#\(segment)" }
    }

    private struct Shade: Identifiable {
        let range: ClosedRange<Date>
        var id: Date { range.lowerBound }
    }

    private func points(endingAt end: Date) -> [Point] {
        series.flatMap { name, _, values in
            values.points(within: StatsModel.window, endingAt: end)
                .map { Point(series: name, segment: $0.segment, time: $0.time, value: $0.value) }
        }
    }

    var body: some View {
        let now = Date()
        let points = points(endingAt: now)
        let window = now.addingTimeInterval(-StatsModel.window)...now
        let shades = gaps.compactMap { $0.clipped(to: window).map(Shade.init) }
        Chart {
            ForEach(shades) { shade in
                RectangleMark(xStart: .value("Time", shade.range.lowerBound),
                              xEnd: .value("Time", shade.range.upperBound))
                    .foregroundStyle(Color.gray.opacity(0.12))
            }
            ForEach(points) { point in
                if stacked {
                    AreaMark(x: .value("Time", point.time), y: .value("Value", point.value),
                             series: .value("Line", point.line))
                        .foregroundStyle(by: .value("Series", point.series))
                } else {
                    LineMark(x: .value("Time", point.time), y: .value("Value", point.value),
                             series: .value("Line", point.line))
                        .foregroundStyle(by: .value("Series", point.series))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.0), range: series.map(\.1))
        .chartXScale(domain: now.addingTimeInterval(-StatsModel.window)...now)
        // Lines and areas stop at the grid: the point kept from just before the
        // window would otherwise be drawn over the card's edge.
        .chartPlotStyle { plot in plot.clipped() }
        .chartYScale(domain: 0...yDomainMaximum(for: points))
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute)) { _ in
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: compact ? 2 : 3)) { value in
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
        // Compact: the figures' color dots identify the series instead of a legend.
        .chartLegend(series.count > 1 && !compact ? .visible : .hidden)
        .frame(height: compact ? max(32, height * 0.5) : height)
    }

    private func yDomainMaximum(for points: [Point]) -> Double {
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
