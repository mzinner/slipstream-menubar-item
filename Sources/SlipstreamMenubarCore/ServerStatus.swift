import Darwin
import Foundation

/// What the launcher records in `build/runtime/serve.lock` while it holds the lock.
///
/// The launcher `execve`s into `server/server.py`, so this pid is the server for
/// its whole life. The file keeps its contents after the server exits, so a
/// recorded pid must still be checked with `ServerProcessInspector`.
public struct ServeLock: Codable, Equatable, Sendable {
    public var pid: Int32
    public var model: String
    public var port: Int
    /// Recorded by launchers with `serve --host`; nil from older ones (127.0.0.1).
    public var host: String?

    public init(pid: Int32, model: String, port: Int, host: String? = nil) {
        self.pid = pid
        self.model = model
        self.port = port
        self.host = host
    }

    /// True when the server accepts connections from other machines.
    public var listensOnNetwork: Bool {
        guard let host else { return false }
        return !["127.0.0.1", "localhost", "::1"].contains(host)
    }

    public static func read(from url: URL) -> ServeLock? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ServeLock.self, from: data)
    }
}

/// Checks whether a pid is alive and is a Slipstream launcher or server.
public enum ServerProcessInspector {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// True for `install/launcher.py serve …` (preparing a model) and `server/server.py …`.
    public static func isSlipstreamServer(_ pid: Int32) -> Bool {
        guard isAlive(pid), let arguments = arguments(of: pid) else { return false }
        return arguments.contains { $0.hasSuffix("install/launcher.py") || $0.hasSuffix("server/server.py") }
    }

    /// A process's argv, read with sysctl(KERN_PROCARGS2).
    public static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (int32), executable path, NUL padding, then argc NUL-terminated strings.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

/// Progress read from the log of a server this app started.
public struct LogProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case starting
        case preparing
        case loading
        case ready
    }

    public var phase: Phase = .starting
    public var preparedParts = 0
    public var lastError: String?

    /// The GGUF converter's parts: 48 layers, MTP layer, MTP combiner, head,
    /// embedding and the n-gram table.
    public static let preparationParts = 53

    public init() {}

    public static func parse(_ log: String) -> LogProgress {
        var progress = LogProgress()
        for line in log.split(whereSeparator: \.isNewline) {
            if line.contains("[Slipstream] Preparing GGUF model") {
                progress.phase = .preparing
                progress.preparedParts = 0
            } else if line.contains("[DONE]") {
                progress.preparedParts += 1
            } else if line.contains(" Loading · ") {
                progress.phase = .loading
            } else if line.contains(" Ready · ") {
                progress.phase = .ready
            }
            if line.hasPrefix("error:") || line.contains("[ERROR]") {
                progress.lastError = String(line)
            }
        }
        return progress
    }
}

/// The state shown in the menu bar.
public enum ServerStatus: Equatable, Sendable {
    case stopped
    /// Running but not ready: launcher building, downloading or starting up.
    case starting
    /// Converting a GGUF model; `parts` of `LogProgress.preparationParts` done.
    case preparing(parts: Int)
    /// HTTP up, weights loading.
    case loading
    case running
    /// Was ready, now failing health checks.
    case unresponsive
    case stopping
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .stopped, .failed: return false
        default: return true
        }
    }

    public var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .preparing(let parts):
            return "Preparing model… \(min(parts, LogProgress.preparationParts))/\(LogProgress.preparationParts)"
        case .loading: return "Loading model…"
        case .running: return "Running"
        case .unresponsive: return "Not responding"
        case .stopping: return "Stopping…"
        case .failed: return "Failed"
        }
    }
}

/// Everything one status poll observed.
public struct StatusObservation: Equatable, Sendable {
    public var processAlive: Bool
    public var healthOK: Bool
    public var readyOK: Bool
    /// From the log, only when this app started the server.
    public var logProgress: LogProgress?
    public var stopping: Bool
    /// The previous status, so a ready server that stops answering reads as unresponsive.
    public var previous: ServerStatus
    /// Consecutive failed `/health` checks while the process is alive.
    public var healthFailures: Int
    /// Exit description when a server this app started has just exited.
    public var exitDescription: String?

    public init(
        processAlive: Bool, healthOK: Bool, readyOK: Bool, logProgress: LogProgress? = nil,
        stopping: Bool = false, previous: ServerStatus = .stopped, healthFailures: Int = 0,
        exitDescription: String? = nil
    ) {
        self.processAlive = processAlive
        self.healthOK = healthOK
        self.readyOK = readyOK
        self.logProgress = logProgress
        self.stopping = stopping
        self.previous = previous
        self.healthFailures = healthFailures
        self.exitDescription = exitDescription
    }
}

public enum StatusResolver {
    /// Failed checks in a row before a ready server counts as unresponsive.
    public static let unresponsiveAfter = 3

    public static func resolve(_ observation: StatusObservation) -> ServerStatus {
        if !observation.processAlive {
            // A server on the port that is not ours or not in the lock still counts.
            if observation.readyOK { return .running }
            if let exit = observation.exitDescription, !observation.stopping {
                return .failed(observation.logProgress?.lastError ?? exit)
            }
            return .stopped
        }
        if observation.stopping { return .stopping }
        if observation.readyOK { return .running }
        // `/ready` is a readiness check: once loaded, the server reports 503 there
        // whenever it is saturated (queue full, engine too busy to answer its status
        // in time, critical memory pressure). Only `/health` says whether it is alive.
        if observation.previous == .running || observation.previous == .unresponsive {
            if observation.healthOK { return .running }
            return observation.healthFailures >= unresponsiveAfter ? .unresponsive : observation.previous
        }
        if observation.healthOK { return .loading }
        switch observation.logProgress?.phase {
        case .preparing: return .preparing(parts: observation.logProgress?.preparedParts ?? 0)
        case .loading: return .loading
        default: return .starting
        }
    }
}
