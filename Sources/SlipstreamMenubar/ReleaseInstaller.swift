import CryptoKit
import Foundation
import SlipstreamMenubarCore

/// Installs the latest Slipstream release the way install.sh does: the package for
/// this Mac from the release's SHA256SUMS, verified, unpacked into
/// ~/.local/share/slipstream/<version>, linked as ~/.local/bin/slipstream, and only
/// the two newest versions kept.
@MainActor
final class ReleaseInstaller: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case resolving
        case downloading(received: Int64, total: Int64)
        case verifying
        case unpacking
        case done(version: String)
        case failed(String)
        case cancelled

        var isRunning: Bool {
            switch self {
            case .resolving, .downloading, .verifying, .unpacking: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var releaseName: String?
    @Published private(set) var packageName: String?

    let repository: String
    nonisolated static var prefix: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/slipstream")
    }

    private var task: Task<Void, Never>?
    private var download: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    /// For the release listing and SHA256SUMS. The download has its own session with
    /// this object as delegate, for progress: async requests on that one never finish.
    private let session = URLSession(configuration: .ephemeral)
    private lazy var downloadSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)

    init(repository: String) {
        self.repository = repository
    }

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func start(onInstalled: @escaping (String) -> Void) {
        guard !phase.isRunning else { return }
        task = Task {
            do {
                let version = try await install()
                phase = .done(version: version)
                onInstalled(version)
            } catch is CancellationError {
                phase = .cancelled
            } catch let error as URLError where error.code == .cancelled {
                phase = .cancelled
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        download?.cancel()
        task?.cancel()
    }

    // MARK: Steps

    private func install() async throws -> String {
        phase = .resolving
        let release = try await latestRelease()
        releaseName = release.tag
        guard let sumsURL = release.assets["SHA256SUMS"] else {
            throw InstallError(message: "Release \(release.tag) of \(repository) has no SHA256SUMS")
        }
        let sums = String(decoding: try await fetch(sumsURL), as: UTF8.self)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let package = ReleasePackages.select(from: sums, macOSMajor: major),
              let packageURL = release.assets[package.name] else {
            throw InstallError(message: "Release \(release.tag) has no package for macOS \(major) on Apple Silicon")
        }
        packageName = package.name

        phase = .downloading(received: 0, total: release.sizes[package.name] ?? 0)
        let zip = try await downloadFile(packageURL)
        defer { try? FileManager.default.removeItem(at: zip) }
        try Task.checkCancellation()

        phase = .verifying
        let digest = try await Task.detached { try Self.sha256(of: zip) }.value
        guard digest == package.sha256.lowercased() else {
            throw InstallError(message: "Checksum mismatch for \(package.name)")
        }

        phase = .unpacking
        return try await Task.detached { try Self.unpackAndLink(zip) }.value
    }

    private struct Release {
        let tag: String
        let assets: [String: URL]
        let sizes: [String: Int64]
    }

    private func latestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw InstallError(message: "Invalid release repository \(repository)")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw InstallError(message: code == 404
                ? "\(repository) has no published release"
                : "GitHub answered \(code) for the latest release of \(repository)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let assets = object["assets"] as? [[String: Any]] else {
            throw InstallError(message: "Could not read the latest release of \(repository)")
        }
        var urls: [String: URL] = [:]
        var sizes: [String: Int64] = [:]
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let link = asset["browser_download_url"] as? String, let url = URL(string: link) else { continue }
            urls[name] = url
            sizes[name] = (asset["size"] as? NSNumber)?.int64Value
        }
        return Release(tag: tag, assets: urls, sizes: sizes)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError(message: "Could not download \(url.lastPathComponent)")
        }
        return data
    }

    private func downloadFile(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloadContinuation = continuation
                let task = downloadSession.downloadTask(with: url)
                download = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in self.download?.cancel() }
        }
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips with ditto (keeps permissions and symlinks), moves the package folder to
    /// <prefix>/<version>, re-points ~/.local/bin/slipstream and prunes old versions.
    nonisolated static func unpackAndLink(_ zip: URL) throws -> String {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("slipstream-install-\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, scratch.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw InstallError(message: "Could not unpack the package") }

        let folders = try fileManager.contentsOfDirectory(atPath: scratch.path).filter { !$0.hasPrefix(".") }
        guard folders.count == 1, let folder = folders.first else {
            throw InstallError(message: "Unexpected package layout")
        }
        let version = ReleasePackages.version(fromPackageFolder: folder) ?? folder
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        let destination = prefix.appendingPathComponent(version)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: scratch.appendingPathComponent(folder), to: destination)

        let executable = destination.appendingPathComponent("bin/slipstream")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw InstallError(message: "The package has no bin/slipstream")
        }
        let binDirectory = InstallationLocator.defaultBinDirectory
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let link = binDirectory.appendingPathComponent("slipstream")
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil || fileManager.fileExists(atPath: link.path) {
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: executable)

        let installed = (try? fileManager.contentsOfDirectory(atPath: prefix.path)) ?? []
        for old in ReleasePackages.superseded(installed, installed: version) {
            try? fileManager.removeItem(at: prefix.appendingPathComponent(old))
        }
        return version
    }
}

extension ReleaseInstaller: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            if case .downloading(_, let known) = phase {
                phase = .downloading(received: totalBytesWritten,
                                     total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : known)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns; keep it.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("slipstream-\(UUID().uuidString).zip")
        let result = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
        MainActor.assumeIsolated {
            if (downloadTask.response as? HTTPURLResponse)?.statusCode != 200 {
                downloadContinuation?.resume(throwing: InstallError(message: "The package download failed"))
            } else {
                downloadContinuation?.resume(with: result)
            }
            downloadContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
    }
}
