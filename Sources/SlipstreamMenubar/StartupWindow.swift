import AppKit
import SlipstreamMenubarCore
import SwiftUI

/// What a starting server is doing, for the startup window: followed from the server's
/// status, or simulated for the setup preview.
@MainActor
final class StartupProgress: ObservableObject {
    enum Phase: Equatable {
        case working(title: String, detail: String?, fraction: Double?)
        case failed(String)
        case done
    }

    @Published private(set) var phase: Phase = .working(title: "Starting the server…", detail: nil, fraction: nil)
    private var task: Task<Void, Never>?

    /// Follows `server` until it runs, fails or stops.
    func follow(_ server: ServerController) {
        task?.cancel()
        task = Task { [weak self] in
            var seenActive = false
            while let self, !Task.isCancelled {
                let status = server.status
                if status.isActive { seenActive = true }
                switch status {
                case .running:
                    phase = .done
                    return
                case .failed(let reason):
                    phase = .failed(reason)
                    return
                case .stopped where seenActive:
                    phase = .failed("The server stopped. Its log is in ~/Library/Logs/Slipstream/server.log.")
                    return
                case .preparing(let parts):
                    let total = LogProgress.preparationParts
                    let left = server.preparationSecondsLeft.map { " · \(TransferEstimator.describe($0)) left" } ?? ""
                    phase = .working(title: "Preparing the model…",
                                     detail: "\(min(parts, total)) of \(total) parts converted\(left)",
                                     fraction: Double(min(parts, total)) / Double(total))
                case .loading:
                    phase = .working(title: "Loading the model…", detail: nil, fraction: nil)
                default:
                    phase = .working(title: "Starting the server…", detail: nil, fraction: nil)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The setup preview: about ten seconds of the same phases.
    func simulate() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            phase = .working(title: "Starting the server…", detail: nil, fraction: nil)
            try? await Task.sleep(for: .seconds(1.5))
            let total = LogProgress.preparationParts
            for parts in stride(from: 0, through: total, by: 4) {
                guard !Task.isCancelled else { return }
                phase = .working(title: "Preparing the model…",
                                 detail: "\(parts) of \(total) parts converted · about \(max(1, (total - parts) / 12)) min left",
                                 fraction: Double(parts) / Double(total))
                try? await Task.sleep(for: .milliseconds(450))
            }
            phase = .working(title: "Loading the model…", detail: nil, fraction: nil)
            try? await Task.sleep(for: .seconds(2))
            phase = .done
        }
    }

    func stop() { task?.cancel() }
}

/// A small window while the server starts: what it is doing, and a Cancel that stops it.
/// It closes when the server runs (opening the web UI first, if asked); closing it only
/// hides it.
@MainActor
final class StartupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var progress: StartupProgress?
    private var watch: Task<Void, Never>?
    private let server: ServerController

    init(server: ServerController) {
        self.server = server
    }

    /// `simulated` runs the setup preview's version, which neither stops nor opens anything.
    func show(openWebUI: Bool, simulated: Bool = false) {
        let progress = StartupProgress()
        self.progress = progress
        let cancel: () -> Void = { [weak self] in
            guard let self else { return }
            if !simulated, case .working = progress.phase { server.stop() }
            close()
        }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        window?.title = simulated ? "Starting Slipstream (Preview)" : "Starting Slipstream"
        window?.contentView = NSHostingView(rootView: StartupView(progress: progress, cancel: cancel))
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        if simulated { progress.simulate() } else { progress.follow(server) }
        watch?.cancel()
        watch = Task { [weak self] in
            for await phase in progress.$phase.values {
                guard let self else { return }
                if phase == .done {
                    if openWebUI, !simulated,
                       let url = URL(string: "http://127.0.0.1:\(self.server.port)/") {
                        NSWorkspace.shared.open(url)
                    }
                    self.close()
                    return
                }
            }
        }
    }

    private func close() {
        watch?.cancel()
        progress?.stop()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Hiding the window leaves the server starting; nothing else waits on it.
        watch?.cancel()
        progress?.stop()
    }
}

private struct StartupView: View {
    @ObservedObject var progress: StartupProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                switch progress.phase {
                case .working(let title, let detail, let fraction):
                    ProgressView().controlSize(.small).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).fontWeight(.semibold)
                        if let fraction { ProgressView(value: fraction) }
                        Text(detail ?? "This can take a few minutes on the first start.")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The server could not start").fontWeight(.semibold)
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("The server is running.").fontWeight(.semibold)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                if case .failed = progress.phase {
                    Button("Close", action: cancel).controlSize(.small).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: cancel).controlSize(.small)
                        .help("Stops the server")
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
