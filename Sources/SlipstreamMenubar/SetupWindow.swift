import AppKit
import SlipstreamMenubarCore
import SwiftUI

/// The first-run setup window: a step sidebar, the step, and a footer with Back and the
/// step's actions. Fixed size; Escape does not close it.
@MainActor
final class SetupWindowController: NSObject {
    let coordinator: SetupCoordinator
    private var window: NSWindow?

    init(coordinator: SetupCoordinator) {
        self.coordinator = coordinator
        super.init()
        coordinator.close = { [weak self] in self?.window?.close() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        coordinator.prepareToShow()
        if window == nil {
            let window = SetupPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 450),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = coordinator.preview
                ? "Setup Slipstream (Preview: nothing is installed or downloaded)" : "Setup Slipstream"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(setup: coordinator))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

}

/// Escape does nothing: setup closes only with its close button or by finishing.
private final class SetupPanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {}
}

// MARK: - Layout

struct SetupView: View {
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        HStack(spacing: 0) {
            StepSidebar(current: setup.step)
                .frame(width: 170)
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch setup.step {
                    case .welcome: WelcomeStep()
                    case .slipstream: SlipstreamStep(setup: setup)
                    case .model: ModelStep(setup: setup)
                    case .server: ServerStep(setup: setup)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                Divider()
                SetupFooter(setup: setup)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 640, height: 450)
    }
}

private struct StepSidebar: View {
    let current: SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                let done = step < current
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle" : "circle")
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    Text(step.title)
                        .fontWeight(step == current ? .semibold : .regular)
                        .foregroundStyle(step == current ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(step == current ? Color.primary.opacity(0.08) : .clear))
                .accessibilityElement(children: .combine)
                .accessibilityValue(done ? "Done" : step == current ? "Current step" : "")
            }
            Spacer()
        }
        .padding(10)
        .padding(.top, 6)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct SetupFooter: View {
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        HStack {
            if setup.step != .welcome {
                Button("Back") { setup.step = SetupStep(rawValue: setup.step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            if setup.step == .server {
                Button("Open settings…") { setup.openSettingsInstead() }
            }
            let primary = primaryAction
            Button(primary.title, action: primary.action)
                .keyboardShortcut(.defaultAction)
                .disabled(!primary.enabled)
                // A new button for each label: one button re-labelled keeps its focus ring at
                // the old label's size (Continue → Install).
                .id(primary.title)
        }
        .controlSize(.large)
    }

    private var primaryAction: (title: String, enabled: Bool, action: () -> Void) {
        switch setup.step {
        case .welcome:
            return ("Continue", true, { setup.step = .slipstream })
        case .slipstream:
            switch setup.engine {
            case .notInstalled: return ("Install", true, setup.install)
            case .installing: return ("Installing…", false, {})
            case .failed: return ("Try Again", true, setup.install)
            case .installed: return ("Continue", true, { setup.step = .model })
            }
        case .model:
            if setup.checkingDisk { return ("Checking…", false, {}) }
            let available = setup.selectedEntry?.isAvailable ?? true
            return (setup.selectionIsOnDisk ? "Continue" : "Download and continue", available,
                    setup.downloadAndContinue)
        case .server:
            if setup.isDownloading { return ("Downloading model…", false, {}) }
            return ("Start server", setup.modelPresent, setup.start)
        }
    }
}

// MARK: - Shared pieces

private struct Hero: View {
    var symbol: String?
    var image: NSImage?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    // The icon's own margin (the macOS icon grid) stays, so it sits at the text's edge.
                    Image(nsImage: image).resizable().frame(width: 64, height: 64).padding(.leading, -6)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tint)
                }
            }
            .padding(.bottom, image == nil ? 8 : 2)
            .accessibilityHidden(true)
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }
}

/// The app's icon: from the bundle, or from the source tree when run unbundled (`swift run`).
@MainActor private let appIcon: NSImage = {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
        return image
    }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
    return NSImage(contentsOf: source) ?? NSApp.applicationIconImage
}()

private struct InfoBox: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack {
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Text(verbatim: row.value)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct InlineError: View {
    let message: String

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .font(.callout)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hero(image: appIcon, title: "Welcome to Slipstream",
                 subtitle: "Slipstream is a lean, high-performance C++ and Metal inference engine built "
                    + "specifically for Apple Silicon. It combines SSD expert streaming with predictive "
                    + "read-ahead and Prompt Lookup + MTP speculative drafting to serve frontier-scale models "
                    + "that exceed your Mac's physical RAM.")
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(symbol: "cpu", title: "Runs on Apple silicon",
                           detail: "Fast local inference with Slipstream.")
                FeatureRow(symbol: "lock", title: "Private by default",
                           detail: "Your prompts never leave this Mac.")
                FeatureRow(symbol: "slider.horizontal.3", title: "Tune it your way",
                           detail: "Adjust settings or fine-tune any time.")
            }
            .padding(.leading, 16)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SlipstreamStep: View {
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hero(symbol: "shippingbox", title: "Install Slipstream",
                 subtitle: "Slipstream is the inference engine that powers the server.")
            InfoBox(rows: [("Version", setup.engineVersion), ("Location", setup.engineLocation), ("Status", status)])
            if setup.installStarted {
                progress.padding(.top, 12)
            }
            if case .failed(let message) = setup.engine {
                InlineError(message: "The installation failed: \(message)").padding(.top, 10)
            }
            if showsUseExisting {
                Button("Already installed? Use existing installation…") { setup.chooseExisting() }
                    .buttonStyle(.link)
                    .padding(.top, 14)
            }
            if let error = setup.pickError {
                InlineError(message: error).padding(.top, 6)
            }
        }
    }

    /// Not once Install was clicked, unless it failed.
    private var showsUseExisting: Bool {
        if case .failed = setup.engine { return true }
        return !setup.installStarted
    }

    private var status: String {
        switch setup.engine {
        case .notInstalled: return "Not installed"
        case .installing(_, let status): return status
        case .installed: return "Installed"
        case .failed: return "Failed"
        }
    }

    @ViewBuilder private var progress: some View {
        switch setup.engine {
        case .installing(let fraction, _):
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
        case .installed:
            ProgressView(value: 1)
        case .notInstalled, .failed:
            EmptyView()
        }
    }
}

private struct ModelStep: View {
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hero(symbol: "archivebox", title: "Choose a model",
                 subtitle: "You can add more models later in Settings.")
            // As many models as the manifest lists: the cards scroll in the space above the footer.
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(setup.manifest.setupEntries) { entry in
                        ModelChoiceRow(name: entry.name, format: entry.kind,
                                       detail: entry.detail(memoryGiB: MachineCheck.memoryGiB),
                                       badge: entry.badge, enabled: entry.isAvailable,
                                       selected: setup.selection == .entry(entry.id)) { setup.select(entry) }
                    }
                    ModelChoiceRow(name: "Model from Hugging Face", format: hubFormat, detail: hubDetail, badge: nil, enabled: true,
                                   selected: isHub) { setup.openHubDialog() }
                    ModelChoiceRow(name: "Other model", format: nil, detail: otherDetail, badge: nil, enabled: true,
                                   selected: isFolder) { setup.chooseFolder() }
                }
                .padding(1)  // the selected card's border is not clipped
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.bottom, setup.modelError == nil ? 16 : 0)
            if let error = setup.modelError {
                InlineError(message: error).padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $setup.hubDialogOpen) {
            HubModelDialog(checker: setup.hubChecker, use: setup.useHubModel, cancel: { setup.hubDialogOpen = false })
        }
    }

    private var isFolder: Bool {
        if case .folder = setup.selection { return true }
        return false
    }

    private var isHub: Bool {
        if case .hub = setup.selection { return true }
        return false
    }

    private var hubFormat: ModelSpec.Kind? {
        if case .hub(let spec) = setup.selection { return spec.kind }
        return nil
    }

    private var hubDetail: String {
        if case .hub(let spec) = setup.selection { return spec.repository }
        return "Choose a model from Hugging Face"
    }

    private var otherDetail: String {
        if case .folder(let url) = setup.selection { return (url.path as NSString).abbreviatingWithTildeInPath }
        return "Choose a folder from disk"
    }
}

private struct ModelChoiceRow: View {
    let name: String
    let format: ModelSpec.Kind?
    let detail: String
    let badge: String?
    let enabled: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fontWeight(.semibold).lineLimit(1)
                    HStack(spacing: 6) {
                        if let format {
                            Text(format.formatLabel)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.6)))
                                .help(format.formatDescription)
                                .accessibilityLabel("Format: \(format.formatLabel)")
                        }
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .background(Capsule().fill(enabled ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.1) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ServerStep: View {
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hero(symbol: "play.circle", title: "Ready to start",
                 subtitle: "Your server will be available at the endpoint below.")
            InfoBox(rows: [("Endpoint", setup.endpoint), ("Model", setup.modelName), ("Engine", setup.engineName)])
            Text("You can change these any time in Settings.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
            if setup.webUIAvailable {
                Toggle("Open Web UI after server startup", isOn: $setup.openWebUIAfterStart)
                    .toggleStyle(.checkbox)
                    .padding(.top, 12)
            }
            if let phase = setup.downloadPhase {
                DownloadStatus(phase: phase, title: setup.downloadTitle, retry: setup.retryDownload)
                    .padding(.top, 12)
            }
            if let error = setup.startError {
                InlineError(message: "The server could not be started: \(error)").padding(.top, 8)
            }
        }
    }

}

private struct DownloadStatus: View {
    let phase: ModelDownloader.Phase
    let title: String
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .preparing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().progressViewStyle(.linear)
                Text("Starting the model download…").font(.callout).foregroundStyle(.secondary)
            }
        case .downloading(let received, let total, _, let secondsLeft):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
                Text(verbatim: "Downloading \(title): \(bytes(received)) of \(bytes(total))"
                     + (secondsLeft.map { " · \(TransferEstimator.describe($0)) left" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        case .stopping:
            Text("Stopping the download…").font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                InlineError(message: "The model download failed: \(message)")
                Spacer()
                Button("Try again", action: retry)
            }
        case .aborted:
            HStack {
                InlineError(message: "The model download stopped.")
                Spacer()
                Button("Try again", action: retry)
            }
        case .idle, .done:
            EmptyView()
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
