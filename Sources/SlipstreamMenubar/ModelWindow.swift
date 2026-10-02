import AppKit
import SlipstreamMenubarCore
import SwiftUI

/// "Download Model…": a picker of the supported models (or a new one by its Hugging Face
/// id), then the checks and questions around the download, and its progress.
@MainActor
final class ModelWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var downloader: ModelDownloader?
    private var picker: ModelPicker?
    private let searchPath: () -> [String]
    /// The Slipstream whose `pull` downloads the model.
    private let installation: () -> SlipstreamInstallation?
    /// "Install Slipstream…", which also updates an installed one.
    private let installSlipstream: () -> Void
    /// The catalog plus models added with New Model…
    private let models: () -> [ModelSpec]
    private let addModel: (ModelSpec) -> Void
    /// Called with the downloaded model, which becomes the configured one.
    private let onDownloaded: (ModelSpec) -> Void
    private let startServer: () -> Void
    private let openSettings: () -> Void

    init(searchPath: @escaping () -> [String], installation: @escaping () -> SlipstreamInstallation?,
         installSlipstream: @escaping () -> Void, models: @escaping () -> [ModelSpec],
         addModel: @escaping (ModelSpec) -> Void, onDownloaded: @escaping (ModelSpec) -> Void,
         startServer: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.searchPath = searchPath
        self.installation = installation
        self.installSlipstream = installSlipstream
        self.models = models
        self.addModel = addModel
        self.onDownloaded = onDownloaded
        self.startServer = startServer
        self.openSettings = openSettings
    }

    /// The picker, or the running download if there is one.
    func show(newModel: Bool = false) {
        if let downloader, downloader.phase.isRunning {
            present(downloader)
            return
        }
        let picker = ModelPicker(models: models(), newModelOpen: newModel)
        self.picker = picker
        let view = ModelPickerView(picker: picker,
                                   choose: { [weak self] model in self?.begin(model) },
                                   add: { [weak self] model in self?.addModel(model) },
                                   close: { [weak self] in self?.window?.close() })
        host(AnyView(view), title: "Download Model", height: 420)
        picker.loadSizes()
    }

    /// Straight to the download of one model, e.g. from Settings.
    func show(model: ModelSpec) {
        if let downloader, downloader.phase.isRunning {
            present(downloader)
            return
        }
        begin(model)
    }

    private func begin(_ model: ModelSpec) {
        // 1. Memory: what the model needs.
        if MachineCheck.memoryGiB < model.minimumMemoryGiB {
            let answer = ask("This Mac has \(MachineCheck.memoryGiB) GB of memory",
                             "\(model.title) needs a \(model.memoryNote). You can still download it, but "
                             + "the server is not expected to start on this Mac.",
                             buttons: ["Download Anyway", "Cancel"], style: .warning)
            guard answer == .alertFirstButtonReturn else { return }
        } else if MachineCheck.memoryGiB < model.recommendedMemoryGiB {
            let answer = ask("Less memory than recommended",
                             "\(model.title) recommends \(model.recommendedMemoryGiB) GB; this Mac has "
                             + "\(MachineCheck.memoryGiB) GB. It should run, with less room for long contexts.",
                             buttons: ["Download", "Cancel"], style: .informational)
            guard answer == .alertFirstButtonReturn else { return }
        }
        // 2. Slipstream, whose `pull` downloads it.
        guard let installation = installation() else {
            let answer = ask("Install Slipstream first",
                             "Models are downloaded by Slipstream itself, into "
                             + "\(ModelStore.folder(for: model.repository).deletingLastPathComponent().path), "
                             + "where its server finds them. Slipstream is not installed yet.",
                             buttons: ["Install Slipstream…", "Cancel"], style: .informational)
            if answer == .alertFirstButtonReturn { installSlipstream() }
            return
        }
        guard installation.supportsPull else {
            let answer = ask("Update Slipstream first",
                             "This \(installation.displayName) cannot download models yet: that needs "
                             + "Slipstream 26.10.3 or later, which has `slipstream pull`."
                             + (installation.kind == .checkout ? " Update the checkout in \(installation.root.path)." : ""),
                             buttons: installation.kind == .release ? ["Update Slipstream…", "Cancel"] : ["OK"],
                             style: .informational)
            if installation.kind == .release, answer == .alertFirstButtonReturn { installSlipstream() }
            return
        }
        // 3. Disk, then the download.
        let downloader = ModelDownloader(model: model, installation: installation, searchPath: searchPath())
        self.downloader = downloader
        present(downloader)
        Task { await self.checkDiskAndRun(downloader) }
    }

    private func checkDiskAndRun(_ downloader: ModelDownloader) async {
        let model = downloader.model
        guard let total = try? await ModelDownloader.totalSize(of: model) else {
            ask("Could not reach Hugging Face", "The file list of \(model.repository) could not be read, so "
                + "neither its size nor the free disk space can be checked. Try again later.", buttons: ["OK"])
            window?.close()
            return
        }
        let free = MachineCheck.freeDiskBytes(at: model.folderURL) ?? 0
        switch DiskCheck.evaluate(total: total, downloaded: downloader.downloadedBytes, free: free,
                                  prepares: model.kind == .gguf) {
        case .ok:
            break
        case .insufficient(let shortBy):
            ask("Not enough free disk space",
                "\(model.title) needs \(bytes(total)), and at least \(bytes(DiskCheck.reserveBytes)) must stay "
                + "free afterwards. \(bytes(free)) are free: make \(bytes(shortBy)) more room, then try again.",
                buttons: ["OK"], style: .critical)
            window?.close()
            return
        case .noRoomToPrepare(let shortBy):
            let answer = ask("Little room left to prepare the model",
                             "The download fits, but on its first start Slipstream writes a prepared copy "
                             + "of about \(bytes(total)) next to it, which needs \(bytes(shortBy)) more than "
                             + "is free. You can make room before starting the server.",
                             buttons: ["Download", "Cancel"], style: .warning)
            guard answer == .alertFirstButtonReturn else {
                window?.close()
                return
            }
        }
        downloader.run { [weak self] success in
            if success { self?.finished(downloader) }
        }
    }

    private func present(_ downloader: ModelDownloader) {
        let view = ModelDownloadView(downloader: downloader, abort: { [weak self] in self?.confirmAbort() },
                                     close: { [weak self] in self?.window?.close() })
        host(AnyView(view), title: "Download Model", height: 230)
    }

    private func host(_ view: AnyView, title: String, height: CGFloat) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = title
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Abort: stop the download, then offer to delete what was downloaded or keep it to resume later.
    private func confirmAbort() {
        guard let downloader, downloader.phase.isRunning else { return }
        let downloading: Bool
        if case .downloading = downloader.phase { downloading = true } else { downloading = false }
        downloader.abort()
        guard downloading || downloader.downloadedBytes > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))  // let pull exit before measuring
            let size = downloader.downloadedBytes
            let answer = ask("Download stopped",
                             "Delete the \(bytes(size)) downloaded so far from \(downloader.model.folder)? "
                             + "If you keep them, the next download continues where this one stopped.",
                             buttons: ["Delete", "Keep"], style: .warning)
            if answer == .alertFirstButtonReturn {
                do {
                    try downloader.deleteDownloadedFiles()
                } catch {
                    ask("Could not delete the files", error.localizedDescription, buttons: ["OK"])
                }
            }
        }
    }

    private func finished(_ downloader: ModelDownloader) {
        let model = downloader.model
        onDownloaded(model)
        let prepares = model.kind == .gguf
            ? " The first start prepares the model, which takes several minutes." : ""
        if MachineCheck.memoryGiB >= model.minimumMemoryGiB {
            let answer = ask("\(model.title) is downloaded",
                             "It is now the model in Settings. Start the server?\(prepares)",
                             buttons: ["Start Server", "Later"], style: .informational)
            window?.close()
            if answer == .alertFirstButtonReturn { startServer() }
        } else {
            let answer = ask("\(model.title) is downloaded",
                             "This Mac has \(MachineCheck.memoryGiB) GB of memory, and the model needs a "
                             + "\(model.memoryNote). Slipstream runs only Qwen3.8-Flash-Next models, which all "
                             + "need that much, so the server is not expected to start here. Settings has Max "
                             + "memory and Max context if you want to try anyway.",
                             buttons: ["Open Settings", "Close"], style: .warning)
            window?.close()
            if answer == .alertFirstButtonReturn { openSettings() }
        }
    }

    var isDownloading: Bool { downloader?.phase.isRunning ?? false }

    /// Before quitting: confirm, then stop the download. Partial files stay for a later resume.
    func confirmQuit() -> Bool {
        guard let downloader, downloader.phase.isRunning else { return true }
        let answer = ask("A model download is running",
                         "Quitting stops it. The \(bytes(downloader.downloadedBytes)) downloaded so far stay in "
                         + "\(downloader.model.folder), and the next download continues from there.",
                         buttons: ["Quit", "Keep Downloading"], style: .warning)
        guard answer == .alertFirstButtonReturn else { return false }
        downloader.stopForQuit()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let downloader, downloader.phase.isRunning {
            confirmAbort()
            return false
        }
        return true
    }

    @discardableResult
    private func ask(_ title: String, _ message: String, buttons: [String],
                     style: NSAlert.Style = .informational) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct ModelDownloadView: View {
    @ObservedObject var downloader: ModelDownloader
    let abort: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(downloader.model.title).font(.headline)
            Text(downloader.command)
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Into \(downloader.model.folder)"
                 + (downloader.model.extraFiles.isEmpty ? "" : ", with the MTP draft head from "
                    + downloader.model.extraFiles.map(\.repository).joined(separator: ", ")))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            switch downloader.phase {
            case .idle, .preparing:
                ProgressView().progressViewStyle(.linear)
                Text("Preparing the download…").font(.caption)
            case .downloading(let received, let total, let rate, let left):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                HStack {
                    Text("\(bytes(received)) of \(bytes(total))")
                    Spacer()
                    if let rate { Text("\(bytes(Int64(rate)))/s") }
                    Text(left.map { TransferEstimator.describe($0) + " left" } ?? "estimating…")
                }
                .font(.caption).monospacedDigit()
            case .stopping:
                ProgressView().progressViewStyle(.linear)
                Text("Stopping…").font(.caption)
            case .done:
                Label("Downloaded to \(downloader.model.folder).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .aborted:
                Text("Download stopped.").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if downloader.phase.isRunning {
                    Button("Abort", action: abort).keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
