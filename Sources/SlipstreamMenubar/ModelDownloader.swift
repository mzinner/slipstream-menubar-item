import AppKit
import SlipstreamMenubarCore

/// Downloads the model with `slipstream pull <repo>` into Slipstream's model store, where
/// `slipstream serve --model <repo>` finds it. Slipstream downloads with the
/// `huggingface_hub` it ships, and fetches the MTP draft head a GGUF repository lacks.
///
/// `pull` prints no machine-readable progress, so progress is measured instead: the total
/// comes from the Hub's file listing, and the bytes so far from the model's folder, where
/// partial files sit in `.cache/huggingface/download/*.incomplete` (a package's files go to
/// the Hub cache, which is measured too).
@MainActor
final class ModelDownloader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case downloading(received: Int64, total: Int64, bytesPerSecond: Double?, secondsLeft: TimeInterval?)
        case stopping
        case done
        case failed(String)
        case aborted

        var isRunning: Bool {
            switch self {
            case .preparing, .downloading, .stopping: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    let model: ModelSpec
    private let installation: SlipstreamInstallation
    private let searchPath: [String]
    private var process: Process?
    private var task: Task<Void, Never>?
    private var aborting = false
    private var stderrTail = ""

    init(model: ModelSpec, installation: SlipstreamInstallation, searchPath: [String]) {
        self.model = model
        self.installation = installation
        self.searchPath = searchPath
    }

    /// The command the window shows: what a terminal user would run for the same result.
    var command: String { "slipstream pull \(model.repository)" }

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs the download after the user's go-ahead.
    func run(onFinished: @escaping (Bool) -> Void) {
        guard !phase.isRunning else { return }
        aborting = false
        task = Task {
            do {
                try await download()
                phase = .done
                onFinished(true)
            } catch is CancellationError {
                phase = .aborted
                onFinished(false)
            } catch {
                phase = aborting ? .aborted : .failed(error.localizedDescription)
                onFinished(false)
            }
        }
    }

    /// Stops a running step. The caller asks about the partial files afterwards.
    func abort() {
        aborting = true
        if let process, process.isRunning {
            phase = .stopping
            process.interrupt()  // SIGINT: pull stops and leaves resumable partial files
            // Files already in transfer finish first, which can take a while; don't wait long.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak process] in
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        task?.cancel()
    }

    /// Stops the download before the app quits, so none is left running unseen.
    func stopForQuit() {
        aborting = true
        task?.cancel()
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.interrupt()
        for signal in [SIGTERM, SIGKILL] {
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(pid, signal) }
        }
    }

    /// The model's folder, and for a package the Hub cache its folder links to.
    private var downloadFolders: [URL] {
        model.kind == .package ? [model.folderURL, ModelStore.hubCacheFolder(for: model.repository)] : [model.folderURL]
    }

    func deleteDownloadedFiles() throws {
        for folder in downloadFolders {
            // attributesOfItem, not fileExists: a package's folder is a link, possibly dangling.
            if (try? FileManager.default.attributesOfItem(atPath: folder.path)) != nil {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    var downloadedBytes: Int64 { downloadFolders.map(ModelPresence.allocatedSize(of:)).reduce(0, +) }

    // MARK: Download

    private func download() async throws {
        phase = .preparing
        let total = try await totalSize()

        var estimator = TransferEstimator()
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let bytes = min(self.downloadedBytes, total)
                estimator.add(bytes: bytes, at: Date())
                if case .stopping = self.phase {} else {
                    self.phase = .downloading(received: bytes, total: total,
                                              bytesPerSecond: estimator.bytesPerSecond,
                                              secondsLeft: estimator.secondsRemaining(total: total))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { monitor.cancel() }
        // A checkout's launcher sets up its Python environment first, from its own folder.
        let status = try await run(installation.launcher, ["pull", model.repository],
                                   directory: installation.root)
        if aborting { throw CancellationError() }
        guard status == 0 else {
            throw DownloadError(message: "\(command) failed (exit \(status)). \(stderrTail)")
        }
    }

    /// Exact bytes the download will total, model and extra files.
    func totalSize() async throws -> Int64 {
        try await Self.totalSize(of: model)
    }

    /// From the Hub's file listings: every file of the model's repository, plus each extra file.
    nonisolated static func totalSize(of model: ModelSpec) async throws -> Int64 {
        guard let url = model.treeURL else { throw DownloadError(message: "Invalid model repository") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, var total = ModelSpec.totalSize(ofTree: data) else {
            throw DownloadError(message: "Could not read the file list of \(model.repository) on Hugging Face")
        }
        for extra in model.extraFiles {
            guard let url = extra.treeURL, let (data, _) = try? await URLSession.shared.data(from: url),
                  let size = ModelSpec.size(of: extra.path, inTree: data) else {
                throw DownloadError(message: "Could not find \(extra.path) in \(extra.repository) on Hugging Face")
            }
            total += size
        }
        return total
    }

    // MARK: Processes

    /// Runs a command to completion, reporting the last line it printed. Cancellable.
    private func run(_ executable: URL, _ arguments: [String], directory: URL,
                     onLine: ((String) -> Void)? = nil) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                               + searchPath).joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        stderrTail = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let last = lines.last else { return }
            Task { @MainActor in
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + "\n" + lines.joined(separator: "\n")).suffix(400))
                onLine?(last)
            }
        }
        self.process = process
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.interrupt() }
        }
    }
}
