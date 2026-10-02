import AppKit
import SlipstreamMenubarCore
import SwiftUI

/// "Download Model…": the checks and questions around the download, and its window.
@MainActor
final class ModelWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var downloader: ModelDownloader?
    private let searchPath: () -> [String]
    /// Called with the downloaded folder, which becomes the configured model.
    private let onDownloaded: (URL) -> Void
    private let startServer: () -> Void
    private let openSettings: () -> Void

    init(searchPath: @escaping () -> [String], onDownloaded: @escaping (URL) -> Void,
         startServer: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.searchPath = searchPath
        self.onDownloaded = onDownloaded
        self.startServer = startServer
        self.openSettings = openSettings
    }

    func show() {
        if let downloader, downloader.phase.isRunning {
            present(downloader)
            return
        }
        let model = ModelSpec.default
        // 1. Memory: the model needs a 64 GB Mac.
        if !MachineCheck.hasEnoughMemory {
            let answer = ask("This Mac has \(MachineCheck.memoryGiB) GB of memory",
                             "\(model.title) needs a Mac with at least \(MachineCheck.requiredMemoryGiB) GB "
                             + "of memory to run. You can still download it, but the server is not "
                             + "expected to start on this Mac.",
                             buttons: ["Download Anyway", "Cancel"], style: .warning)
            guard answer == .alertFirstButtonReturn else { return }
        }
        // 2. hf, and Homebrew to install it.
        let paths = searchPath()
        if Homebrew.hf(searchPath: paths) == nil, Homebrew.brew() == nil {
            let answer = ask("Install Homebrew?",
                             "The model is downloaded with Hugging Face's `hf` tool, which is installed with "
                             + "Homebrew, and Homebrew is not installed. Install it now with its official "
                             + "installer? It opens in Terminal and asks for your password:\n\n"
                             + Homebrew.installCommand,
                             buttons: ["Install Homebrew", "Cancel"], style: .informational)
            guard answer == .alertFirstButtonReturn else { return }
            do {
                try ModelDownloader.openHomebrewInstaller()
            } catch {
                ask("Could not start the Homebrew installer", error.localizedDescription, buttons: ["OK"])
                return
            }
        }
        // 3. Disk: the GGUF files, and about as much again for the package prepared on first serve.
        let downloader = ModelDownloader(model: model, searchPath: paths)
        self.downloader = downloader
        present(downloader)
        Task { await self.checkDiskAndRun(downloader) }
    }

    /// At least 10 GB must stay free once the download is done; room for the prepared
    /// copy written on the first start is only advised.
    private func checkDiskAndRun(_ downloader: ModelDownloader) async {
        let model = downloader.model
        guard let total = try? await ModelDownloader.totalSize(of: model) else {
            ask("Could not reach Hugging Face", "The file list of \(model.repository) could not be read, so "
                + "neither its size nor the free disk space can be checked. Try again later.", buttons: ["OK"])
            window?.close()
            return
        }
        let free = MachineCheck.freeDiskBytes(at: model.folderURL) ?? 0
        switch DiskCheck.evaluate(total: total, downloaded: downloader.downloadedBytes, free: free) {
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
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Download Model"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Abort: stop hf, then offer to delete what was downloaded or keep it to resume later.
    private func confirmAbort() {
        guard let downloader, downloader.phase.isRunning else { return }
        let downloading: Bool
        if case .downloading = downloader.phase { downloading = true } else { downloading = false }
        downloader.abort()
        guard downloading || downloader.downloadedBytes > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))  // let hf exit before measuring
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
        onDownloaded(downloader.model.folderURL)
        if MachineCheck.hasEnoughMemory {
            let answer = ask("\(downloader.model.title) is downloaded",
                             "It is now the model in Settings. Start the server? The first start prepares "
                             + "the model, which takes several minutes.",
                             buttons: ["Start Server", "Later"], style: .informational)
            window?.close()
            if answer == .alertFirstButtonReturn { startServer() }
        } else {
            let answer = ask("\(downloader.model.title) is downloaded",
                             "This Mac has \(MachineCheck.memoryGiB) GB of memory, and the model needs "
                             + "\(MachineCheck.requiredMemoryGiB) GB. Open Settings to choose a smaller model "
                             + "and adjust Max memory and Max context before starting the server.",
                             buttons: ["Open Settings", "Close"], style: .warning)
            window?.close()
            if answer == .alertFirstButtonReturn { openSettings() }
        }
    }

    var isDownloading: Bool { downloader?.phase.isRunning ?? false }

    /// Before quitting: confirm, then stop hf. Partial files stay for a later resume.
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
            Text("hf download \(downloader.model.repository) --local-dir \(downloader.model.folder)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(downloader.model.extraFiles, id: \.path) { extra in
                Text("hf download \(extra.repository) \(extra.path) --local-dir \(downloader.model.folder)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch downloader.phase {
            case .idle, .preparing:
                ProgressView().progressViewStyle(.linear)
                Text("Preparing the download…").font(.caption)
            case .waitingForHomebrew:
                ProgressView().progressViewStyle(.linear)
                Text("Waiting for the Homebrew installer in Terminal to finish…").font(.caption)
            case .installingHF(let line):
                ProgressView().progressViewStyle(.linear)
                Text("Installing hf with Homebrew: \(line)").font(.caption).lineLimit(2)
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
