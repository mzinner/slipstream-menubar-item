import AppKit
import SlipstreamMenubarCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private var server: ServerController!
    private let stats = StatsModel()
    private var menu: MenuController!
    private var panel: StatsPanelController!
    private var settings: SettingsWindowController!
    private var pollTask: Task<Void, Never>?
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = ServerController(config: store.load(), apiKey: APIKeyStore.load())
        panel = StatsPanelController(server: server, stats: stats) { [weak self] _ in self?.menu?.update() }
        settings = SettingsWindowController(server: server) { [weak self] config, key, restart in
            self?.apply(config, apiKey: key, restart: restart)
        }
        menu = MenuController(server: server, actions: .init(
            start: { [weak self] in self?.start() },
            stop: { [weak self] in self?.server.stop(); self?.menu.update() },
            forceStop: { [weak self] in self?.server.forceStop(); self?.menu.update() },
            togglePanel: { [weak self] in self?.panel.toggle(); self?.menu.update() },
            isPanelVisible: { [weak self] in self?.panel.isVisible ?? false },
            settings: { [weak self] in self?.settings.show() },
            about: { [weak self] in self?.showAbout() },
            menuOpened: { [weak self] open in self?.menuOpen = open },
            readout: { [weak self] in
                guard let rates = self?.stats.rates else { return (0, 0) }
                return (rates.promptTokensPerSecond, rates.outputTokensPerSecond)
            }
        ))

        // Detect a server that is already running before deciding to start one.
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.tick()
            if self.server.config.startServerOnLaunch, !self.server.status.isActive {
                self.start()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.pollInterval))
                await self.tick()
            }
        }
        if server.config.model.isEmpty { settings.show() }
        if CommandLine.arguments.contains("--show-panel") { panel.show() }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()  // the server keeps running
    }

    /// Two seconds while serving or someone is looking (the rates average over three),
    /// one while the state is changing, three when stopped.
    private var pollInterval: Double {
        switch server.status {
        case .running, .unresponsive: return 2
        case .stopped, .failed: return panel.isVisible || menuOpen ? 2 : 3
        default: return 1
        }
    }

    private func tick() async {
        await server.refresh()
        await stats.sample(port: server.port, apiKey: server.apiKey, serverReady: server.status == .running)
        menu.update()
    }

    private func start() {
        server.acknowledgeFailure()
        do {
            try server.start()
        } catch {
            alert("The server could not be started", error.localizedDescription)
        }
        menu.update()
    }

    private func apply(_ config: ServerConfig, apiKey: String?, restart: Bool) {
        do {
            try store.save(config)
        } catch {
            alert("Settings could not be saved", error.localizedDescription)
            return
        }
        APIKeyStore.save(apiKey)
        server.config = config
        server.apiKey = apiKey
        if restart { Task { await restartServer() } }
    }

    private func restartServer() async {
        server.stop()
        for _ in 0..<60 where server.status.isActive {
            try? await Task.sleep(for: .seconds(1))
            await server.refresh()
        }
        start()
    }

    private func showAbout() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        var lines = ["Start, stop and watch a local Slipstream server.",
                     "Checkout: \((server.config.repoPath as NSString).abbreviatingWithTildeInPath)"]
        if let build = EngineBuild.identifier(repo: server.config.repoURL) {
            lines.append("Engine build: \(build)")
        }
        if let model = server.model ?? (server.config.model.isEmpty ? nil : server.config.model) {
            lines.append("Model: \((model as NSString).lastPathComponent)")
        }
        lines.append("Server log: ~/Library/Logs/Slipstream/server.log")
        credits.append(NSAttributedString(string: lines.joined(separator: "\n"), attributes: body))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Slipstream Menubar",
            .credits: credits,
        ])
    }

    /// Development aid: renders the stats panel to a PNG once some history exists,
    /// and the menu bar item, with and without readouts, beside it.
    private func snapshot(to url: URL) {
        let itemURL = url.deletingPathExtension().appendingPathExtension("menubar.png")
        writeMenuBarSample(to: itemURL)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))  // the readout appears once the server is seen
            let widths = menu.measuredWidths
            let text = "item \(widths.item) pt, image \(widths.image) pt\n"
            try? text.write(to: url.deletingPathExtension().appendingPathExtension("widths.txt"),
                            atomically: true, encoding: .utf8)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            let view = StatsContent(server: server, stats: stats)
                .frame(width: 460)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
    }

    private func writeMenuBarSample(to url: URL) {
        let samples = [StatusItemImage.make(rates: nil), StatusItemImage.make(rates: (342, 41.2)),
                       StatusItemImage.make(rates: (12_400, 8.7)), StatusItemImage.make(rates: (0, 0))]
        let scale: CGFloat = 4
        let spacing: CGFloat = 12
        let width = samples.reduce(spacing) { $0 + $1.size.width + spacing }
        let size = NSSize(width: width * scale, height: StatusItemImage.height * scale)
        let canvas = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.93, alpha: 1).setFill()
            rect.fill()
            var x = spacing
            for sample in samples {
                sample.draw(in: NSRect(x: x * scale, y: 0, width: sample.size.width * scale, height: size.height))
                x += sample.size.width + spacing
            }
            return true
        }
        if let tiff = canvas.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
