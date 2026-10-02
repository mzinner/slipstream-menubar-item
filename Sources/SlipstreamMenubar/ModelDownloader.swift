import AppKit
import SlipstreamMenubarCore

/// Downloads the model with `hf download <repo> --local-dir <folder>`, installing `hf`
/// with Homebrew (and Homebrew itself, if the user agrees) first.
///
/// `hf` prints no machine-readable progress (`--format json` reports only the final
/// path), so progress is measured instead: the total comes from the Hub's file
/// listing, and the bytes so far from the folder, where hf keeps partial files in
/// `.cache/huggingface/download/*.incomplete`.
@MainActor
final class ModelDownloader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForHomebrew
        case installingHF(String)
        case preparing
        case downloading(received: Int64, total: Int64, bytesPerSecond: Double?, secondsLeft: TimeInterval?)
        case stopping
        case done
        case failed(String)
        case aborted

        var isRunning: Bool {
            switch self {
            case .waitingForHomebrew, .installingHF, .preparing, .downloading, .stopping: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    let model: ModelSpec
    private let searchPath: [String]
    private var process: Process?
    private var task: Task<Void, Never>?
    private var aborting = false
    private var stderrTail = ""

    init(model: ModelSpec, searchPath: [String]) {
        self.model = model
        self.searchPath = searchPath
    }

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs the steps after the user's go-ahead: `hf` (via Homebrew), then the download.
    func run(onFinished: @escaping (Bool) -> Void) {
        guard !phase.isRunning else { return }
        aborting = false
        task = Task {
            do {
                let hf = try await ensureHF()
                try await download(with: hf)
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
            process.interrupt()  // SIGINT: hf stops and leaves resumable partial files
            // hf does not always stop on SIGINT alone (a transfer thread may hold it).
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak process] in
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        task?.cancel()
    }

    /// Stops hf before the app quits, so no download is left running unseen.
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

    func deleteDownloadedFiles() throws {
        if FileManager.default.fileExists(atPath: model.folderURL.path) {
            try FileManager.default.removeItem(at: model.folderURL)
        }
    }

    var downloadedBytes: Int64 { ModelPresence.allocatedSize(of: model.folderURL) }

    // MARK: hf

    /// hf from Homebrew or PATH; installs it with `brew install hf` when missing. A
    /// missing Homebrew is installed in Terminal by the caller beforehand.
    private func ensureHF() async throws -> URL {
        if let hf = Homebrew.hf(searchPath: searchPath) { return hf }
        guard let brew = Homebrew.brew() else {
            phase = .waitingForHomebrew
            while Homebrew.brew() == nil {
                try await Task.sleep(for: .seconds(2))
            }
            return try await ensureHF()
        }
        phase = .installingHF("brew install hf")
        let status = try await run(brew, ["install", "hf"]) { [weak self] line in
            self?.phase = .installingHF(line)
        }
        guard status == 0, let hf = Homebrew.hf(searchPath: searchPath) else {
            throw DownloadError(message: "`brew install hf` failed (exit \(status)). \(stderrTail)")
        }
        return hf
    }

    // MARK: Download

    private func download(with hf: URL) async throws {
        phase = .preparing
        let total = try await totalSize()
        try FileManager.default.createDirectory(at: model.folderURL, withIntermediateDirectories: true)

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
        let status = try await run(hf, ["download", model.repository, "--local-dir", model.folderURL.path])
        if aborting { throw CancellationError() }
        guard status == 0 else {
            throw DownloadError(message: "hf download failed (exit \(status)). \(stderrTail)")
        }
    }

    /// Exact bytes the download will total, from the Hub's file listing.
    private func totalSize() async throws -> Int64 {
        guard let url = model.treeURL else { throw DownloadError(message: "Invalid model repository") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let total = ModelSpec.totalSize(ofTree: data) else {
            throw DownloadError(message: "Could not read the file list of \(model.repository) on Hugging Face")
        }
        return total
    }

    // MARK: Processes

    /// Runs a command to completion, reporting the last line it printed. Cancellable.
    private func run(_ executable: URL, _ arguments: [String],
                     onLine: ((String) -> Void)? = nil) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                               + searchPath).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
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

    // MARK: Homebrew

    /// Opens Terminal with Homebrew's official installer: it asks for a password and a
    /// confirmation, which only a terminal can answer. `run` then waits for `brew`.
    static func openHomebrewInstaller() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("install-homebrew.command")
        let body = """
        #!/bin/bash
        echo "Installing Homebrew for Slipstream Menubar, with Homebrew's official installer:"
        echo
        echo '  \(Homebrew.installCommand)'
        echo
        \(Homebrew.installCommand)
        echo
        echo "Done. You can close this window; Slipstream Menubar continues on its own."
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}
