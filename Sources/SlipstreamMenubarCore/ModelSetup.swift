import Darwin
import Foundation

/// The model "Download Model…" installs: the Swift variant from Slipstream's README,
/// `hf download nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF --local-dir
/// ~/models/swift-qwen38-flash-next-v3`.
public struct ModelSpec: Codable, Equatable, Sendable {
    /// What the download is, which decides how the server gets it ready.
    public enum Kind: String, Codable, Sendable {
        /// GGUF shards of Qwen3.8-Flash-Next (`qwen4exp`): converted into `prepared/` on first start.
        case gguf
        /// A ready-to-run Slipstream package (`manifest.json` and packed weights).
        case package
    }

    /// A single file from another repository, downloaded into the model's folder.
    public struct ExtraFile: Codable, Equatable, Sendable {
        public var repository: String
        public var path: String

        public var treeURL: URL? {
            URL(string: "https://huggingface.co/api/models/\(repository)/tree/main?recursive=true")
        }
    }

    public var repository: String
    public var folder: String
    public var title: String
    public var extraFiles: [ExtraFile] = []
    public var kind: Kind = .gguf
    /// Below this the server is not expected to start.
    public var minimumMemoryGiB: Int = 64
    /// What the model's authors recommend.
    public var recommendedMemoryGiB: Int = 64

    /// The MTP draft head (speculative decoding) is only in the base model's repository;
    /// the converter looks for it in the model's own `MTP/` folder.
    public static let mtpDraftHead = ExtraFile(repository: "nitinpanj/qwen38-flash-next-v3",
                                               path: "MTP/mtp-shared-Q4_K_M.gguf")

    public static let swiftQwen38FlashNext = ModelSpec(
        repository: "nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF",
        folder: "~/models/swift-qwen38-flash-next-v3",
        title: "Swift-Qwen3.8-Flash-Next V3",
        extraFiles: [mtpDraftHead])

    /// The README's alternative: the dense base model, which ships its MTP head.
    public static let qwen38FlashNext = ModelSpec(
        repository: "nitinpanj/qwen38-flash-next-v3",
        folder: "~/models/qwen38-flash-next-v3",
        title: "Qwen3.8-Flash-Next V3")

    /// The models the app offers. The Slipstream v2 engine loads only Qwen3.8-Flash-Next
    /// (`splash-packed-q4-qwen4exp`, runtime/model/ModelDescriptor.mm): the
    /// incoai/Qwen3.8-27B-Splash and Qwen3.6-35B-A3B-Splash packages that its launcher still
    /// lists (inherited from Splash 1.0) fail with "unsupported weight format".
    public static let catalog: [ModelSpec] = [swiftQwen38FlashNext, qwen38FlashNext]

    /// The catalog or custom model whose folder is `path`, if any.
    public static func matching(path: String, in models: [ModelSpec]) -> ModelSpec? {
        let target = (path as NSString).expandingTildeInPath
        return models.first { $0.folderURL.path == target }
    }

    public init(repository: String, folder: String, title: String, extraFiles: [ExtraFile] = [],
                kind: Kind = .gguf, minimumMemoryGiB: Int = 64, recommendedMemoryGiB: Int = 64) {
        self.repository = repository
        self.folder = folder
        self.title = title
        self.extraFiles = extraFiles
        self.kind = kind
        self.minimumMemoryGiB = minimumMemoryGiB
        self.recommendedMemoryGiB = recommendedMemoryGiB
    }

    /// "Qwen3.8-27B (17.4 GB download, 36 GB Mac, 48 GB recommended)" style summary of needs.
    public var memoryNote: String {
        minimumMemoryGiB == recommendedMemoryGiB
            ? "\(minimumMemoryGiB) GB Mac"
            : "\(minimumMemoryGiB) GB Mac, \(recommendedMemoryGiB) GB recommended"
    }

    /// `SLIPSTREAM_MENUBAR_MODEL_REPO` / `_MODEL_DIR` swap in a small repository to test
    /// the download flow without fetching 100 GB.
    public static var `default`: ModelSpec {
        let environment = ProcessInfo.processInfo.environment
        guard let repository = environment["SLIPSTREAM_MENUBAR_MODEL_REPO"], !repository.isEmpty else {
            return .swiftQwen38FlashNext
        }
        // SLIPSTREAM_MENUBAR_MODEL_EXTRA=owner/repo:path adds one extra file, like the MTP head.
        let extra = environment["SLIPSTREAM_MENUBAR_MODEL_EXTRA"]?.split(separator: ":", maxSplits: 1)
            .map(String.init)
        return ModelSpec(repository: repository,
                         folder: environment["SLIPSTREAM_MENUBAR_MODEL_DIR"] ?? "~/models/test-model",
                         title: repository,
                         extraFiles: extra?.count == 2 ? [ExtraFile(repository: extra![0], path: extra![1])] : [])
    }

    public var folderURL: URL { URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }
    public var treeURL: URL? {
        URL(string: "https://huggingface.co/api/models/\(repository)/tree/main?recursive=true")
    }

    /// The size of one file in a Hub `tree` listing.
    public static func size(of path: String, inTree data: Data) -> Int64? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.first { $0["path"] as? String == path }
            .flatMap { ($0["size"] as? NSNumber)?.int64Value }
    }

    /// Sum of the file sizes in a Hub `tree` listing: what the download will total.
    public static func totalSize(ofTree data: Data) -> Int64? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let sizes = entries.compactMap { entry -> Int64? in
            guard entry["type"] as? String == "file" else { return nil }
            return (entry["size"] as? NSNumber)?.int64Value
        }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// Whether a configured model can be served as it is.
public enum ModelPresence {
    /// True for a Hub repo id (the launcher downloads those itself), or a local folder
    /// holding GGUF shards or a prepared package.
    public static func isAvailable(_ model: String, fileManager: FileManager = .default) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let path = (trimmed as NSString).expandingTildeInPath
        let local = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")
        guard local else { return trimmed.contains("/") }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if fileManager.fileExists(atPath: path + "/manifest.json")
            || fileManager.fileExists(atPath: path + "/prepared/manifest.json") { return true }
        let files = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        return files.contains { $0.hasSuffix(".gguf") }
    }

    /// Bytes a folder takes on disk, including hf's `.incomplete` partial downloads.
    public static func allocatedSize(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// What this Mac brings to a 100 GB model.
public enum MachineCheck {
    public static let requiredMemoryGiB = 64

    public static var memoryGiB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    public static var hasEnoughMemory: Bool { memoryGiB >= requiredMemoryGiB }

    /// Only a 64 GB Mac needs the GPU wired limit raised: larger ones have room anyway.
    public static func needsGPULimitRaise(memoryGiB: Int = memoryGiB) -> Bool {
        memoryGiB >= requiredMemoryGiB && memoryGiB < 96
    }

    public static func freeDiskBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// `iogpu.wired_limit_mb`: how much memory the GPU may wire. macOS keeps it at about
/// 48 GiB on a 64 GB Mac; Slipstream wants 58 GiB (59392). It resets at every boot.
public enum GPUMemoryLimit {
    public static let recommendedMB = 59392
    public static let sysctlName = "iogpu.wired_limit_mb"

    /// The current value, or nil where the sysctl does not exist. 0 means the default.
    public static func currentMB() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(sysctlName, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// The shell command that sets it; it needs administrator rights.
    public static func command(megabytes: Int) -> String {
        "/usr/sbin/sysctl \(sysctlName)=\(megabytes)"
    }
}

/// Homebrew and the `hf` command it installs.
public enum Homebrew {
    public static let installCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    public static func brew(fileManager: FileManager = .default) -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// `hf` from Homebrew, or anywhere on the given PATH.
    public static func hf(searchPath: [String] = [], fileManager: FileManager = .default) -> URL? {
        (["/opt/homebrew/bin", "/usr/local/bin"] + searchPath)
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).appendingPathComponent("hf") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

/// Download speed and time left from (time, bytes) samples over a sliding window.
public struct TransferEstimator: Sendable {
    public let window: TimeInterval
    private var samples: [(time: Date, bytes: Int64)] = []

    public init(window: TimeInterval = 20) {
        self.window = window
    }

    public mutating func add(bytes: Int64, at time: Date) {
        samples.append((time, bytes))
        samples.removeAll { time.timeIntervalSince($0.time) > window }
    }

    /// Bytes per second over the window; nil until two samples span a second.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.time.timeIntervalSince(first.time)
        guard seconds >= 1, last.bytes >= first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / seconds
    }

    public func secondsRemaining(total: Int64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0, let last = samples.last else { return nil }
        return Double(max(0, total - last.bytes)) / rate
    }

    /// "about 1 h 12 min", "about 4 min", "less than a minute".
    public static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min" }
        return "about \(minutes / 60) h \(minutes % 60) min"
    }
}

/// Whether a model download fits on the disk.
public enum DiskCheck {
    /// Free space that must remain once the download is complete.
    public static let reserveBytes: Int64 = 10_000_000_000

    public enum Verdict: Equatable, Sendable {
        case ok
        /// The download would leave less than the reserve: it must not start.
        /// `shortBy` is how much more space it needs.
        case insufficient(shortBy: Int64)
        /// The download fits, but the first start's prepared copy (about the size of the
        /// download again) would not. A warning, not a block.
        case noRoomToPrepare(shortBy: Int64)
    }

    /// `downloaded` is what an earlier, stopped download already left on disk; `prepares`
    /// says whether the first start writes a prepared copy (GGUF models do, packages don't).
    public static func evaluate(total: Int64, downloaded: Int64, free: Int64, prepares: Bool = true) -> Verdict {
        let remaining = max(0, total - downloaded)
        let afterDownload = free - remaining
        if afterDownload < reserveBytes { return .insufficient(shortBy: reserveBytes - afterDownload) }
        guard prepares else { return .ok }
        let afterPreparing = afterDownload - total
        if afterPreparing < reserveBytes { return .noRoomToPrepare(shortBy: reserveBytes - afterPreparing) }
        return .ok
    }
}
