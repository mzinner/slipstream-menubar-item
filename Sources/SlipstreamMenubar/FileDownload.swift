import Foundation

/// One file download with progress, cancellable. Used by the Slipstream installer and
/// the app's own update. Async requests on a session with a delegate never finish, so
/// this has its own session and reports through the delegate.
@MainActor
final class FileDownload: NSObject {
    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Bytes received and expected (0 when the server does not say).
    var onProgress: (Int64, Int64) -> Void = { _, _ in }

    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)

    /// Downloads `url` to a temporary file the caller owns.
    func run(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

extension FileDownload: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            onProgress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns; keep it.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("slipstream-\(UUID().uuidString)-\(location.lastPathComponent)")
        let result = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
        MainActor.assumeIsolated {
            if (downloadTask.response as? HTTPURLResponse)?.statusCode != 200 {
                try? FileManager.default.removeItem(at: kept)
                continuation?.resume(throwing: Failed(message: "The download of \(downloadTask.originalRequest?.url?.lastPathComponent ?? "the file") failed"))
            } else {
                continuation?.resume(with: result)
            }
            continuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
