import AppKit
import SwiftUI

/// The "Install Slipstream" window: what will happen, a progress bar while it does,
/// and the result.
@MainActor
final class InstallWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var installer: ReleaseInstaller?
    private let repository: () -> String
    private let onInstalled: () -> Void

    init(repository: @escaping () -> String, onInstalled: @escaping () -> Void) {
        self.repository = repository
        self.onInstalled = onInstalled
    }

    /// Shows the window; with `startImmediately` the download begins at once.
    func show(startImmediately: Bool = false) {
        if installer == nil || !(installer!.phase.isRunning) {
            installer = ReleaseInstaller(repository: repository())
        }
        guard let installer else { return }
        let view = InstallView(installer: installer,
                               install: { [weak self] in self?.begin() },
                               close: { [weak self] in self?.window?.close() })
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Install Slipstream"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if startImmediately { begin() }
    }

    private func begin() {
        installer?.start { [weak self] _ in self?.onInstalled() }
    }

    func windowWillClose(_ notification: Notification) {
        installer?.cancel()
    }
}

private struct InstallView: View {
    @ObservedObject var installer: ReleaseInstaller
    let install: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Slipstream").font(.headline)
            Text("Downloads the latest release from github.com/\(installer.repository), verifies "
                 + "its checksum, installs it into ~/.local/share/slipstream and links "
                 + "~/.local/bin/slipstream. The two newest versions are kept.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            switch installer.phase {
            case .idle:
                EmptyView()
            case .resolving:
                ProgressView().progressViewStyle(.linear)
                Text("Looking up the latest release…").font(.caption)
            case .downloading(let received, let total):
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text("Downloading \(installer.packageName ?? "package"): "
                     + "\(bytes(received)) of \(total > 0 ? bytes(total) : "…")")
                    .font(.caption).monospacedDigit()
            case .verifying:
                ProgressView().progressViewStyle(.linear)
                Text("Verifying the checksum…").font(.caption)
            case .unpacking:
                ProgressView().progressViewStyle(.linear)
                Text("Unpacking and linking…").font(.caption)
            case .done(let version):
                Label("Installed Slipstream \(version). The app uses it from now on.",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Text("Cancelled.").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if installer.phase.isRunning {
                    Button("Cancel") { installer.cancel() }.keyboardShortcut(.cancelAction)
                } else if case .done = installer.phase {
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button(installer.phase == .idle ? "Install" : "Try Again", action: install)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
