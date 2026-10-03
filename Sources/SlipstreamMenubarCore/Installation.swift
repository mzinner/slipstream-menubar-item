import Darwin
import Foundation

/// A Slipstream the app can start: an installed release or a source checkout.
public struct SlipstreamInstallation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A release package, as install.sh puts it: `<prefix>/<version>/bin/slipstream`
        /// next to `release.json`. Its data lives in Application Support.
        case release
        /// A source checkout with the `slipstream` launcher at its root.
        case checkout
    }

    public var kind: Kind
    /// What to run with `serve …`.
    public var launcher: URL
    /// The package or checkout root (holds `install/launcher.py`).
    public var root: URL
    /// From the package's `release.json`; nil for a checkout.
    public var version: String?

    public init(kind: Kind, launcher: URL, root: URL, version: String?) {
        self.kind = kind
        self.launcher = launcher
        self.root = root
        self.version = version
    }

    /// Where this installation's launcher records a running server.
    public var serveLockURL: URL {
        switch kind {
        case .release: return Self.releaseDataDirectory.appendingPathComponent("runtime/serve.lock")
        case .checkout: return root.appendingPathComponent("build/runtime/serve.lock")
        }
    }

    /// Whether its launcher accepts `serve --host` (npanj/slipstream#5).
    public var supportsHost: Bool {
        let source = try? String(contentsOf: root.appendingPathComponent("install/launcher.py"), encoding: .utf8)
        return source?.contains("\"--host\"") ?? false
    }

    /// Whether its launcher has `slipstream pull`, which "Download Model…" runs.
    public var supportsPull: Bool {
        let source = try? String(contentsOf: root.appendingPathComponent("install/launcher.py"), encoding: .utf8)
        return source?.contains("\"pull\"") ?? false
    }

    /// Whether its launcher has `pull --check`: Slipstream says itself whether it can serve a
    /// repository. Older ones are checked by the app.
    public var supportsPullCheck: Bool {
        let source = try? String(contentsOf: root.appendingPathComponent("install/launcher.py"), encoding: .utf8)
        return source?.contains("\"--check\"") ?? false
    }

    /// Whether its launcher has `serve --keep-gguf`: such a Slipstream uses a downloaded GGUF
    /// model's files up while preparing it, unless told to keep them. Older ones always keep
    /// them, and preparing then needs the model's size again.
    public var supportsKeepGGUF: Bool {
        let source = try? String(contentsOf: root.appendingPathComponent("install/launcher.py"), encoding: .utf8)
        return source?.contains("\"--keep-gguf\"") ?? false
    }

    /// The Slipstream a user points setup at: its `slipstream` executable, a release's folder
    /// (`<root>/bin/slipstream`) or a checkout's. Too old to download models is refused too.
    public static func chosen(_ url: URL, fileManager: FileManager = .default) -> Result<SlipstreamInstallation, ChoiceError> {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .failure(.notFound) }
        let executables = isDirectory.boolValue
            ? [url.appendingPathComponent("bin/slipstream"), url.appendingPathComponent("slipstream")]
            : [url]
        guard let installation = executables.lazy.compactMap({ at(executable: $0, fileManager: fileManager) }).first
        else { return .failure(.notFound) }
        guard installation.supportsPull else { return .failure(.tooOld(installation.displayName)) }
        return .success(installation)
    }

    public enum ChoiceError: Error, Equatable, LocalizedError {
        case notFound
        case tooOld(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "That folder doesn't contain Slipstream. Choose the folder where it's installed."
            case .tooOld(let name):
                return "\(name) is too old for this app: it needs Slipstream 26.10.3 or later, which can download models."
            }
        }
    }

    /// Settings that run this installation.
    public func applied(to config: ServerConfig) -> ServerConfig {
        var config = config
        switch kind {
        case .checkout:
            config.useCheckout = true
            config.repoPath = root.path
            config.slipstreamPath = ""
        case .release:
            config.useCheckout = false
            config.slipstreamPath = launcher.path
        }
        return config
    }

    public var displayName: String {
        switch kind {
        case .release: return "Slipstream \(version ?? "release")"
        case .checkout: return "Slipstream checkout"
        }
    }

    /// `paths.DATA` of a packaged launcher.
    public static var releaseDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slipstream-v2")
    }

    /// Recognises what an executable named `slipstream` belongs to, following symlinks
    /// (`~/.local/bin/slipstream` points into `~/.local/share/slipstream/<version>/bin`).
    public static func at(executable: URL, fileManager: FileManager = .default) -> SlipstreamInstallation? {
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        let resolved = executable.resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()
        // A release: <root>/bin/slipstream with <root>/release.json.
        if directory.lastPathComponent == "bin" {
            let root = directory.deletingLastPathComponent()
            let release = root.appendingPathComponent("release.json")
            if fileManager.fileExists(atPath: release.path),
               fileManager.fileExists(atPath: root.appendingPathComponent("install/launcher.py").path) {
                return SlipstreamInstallation(kind: .release, launcher: executable, root: root,
                                              version: releaseVersion(at: release))
            }
        }
        // A checkout: <root>/slipstream next to install/launcher.py, without release.json.
        return checkout(at: directory, fileManager: fileManager)
    }

    public static func checkout(at root: URL, fileManager: FileManager = .default) -> SlipstreamInstallation? {
        let launcher = root.appendingPathComponent("slipstream")
        guard fileManager.isExecutableFile(atPath: launcher.path),
              fileManager.fileExists(atPath: root.appendingPathComponent("install/launcher.py").path),
              !fileManager.fileExists(atPath: root.appendingPathComponent("release.json").path)
        else { return nil }
        return SlipstreamInstallation(kind: .checkout, launcher: launcher, root: root, version: nil)
    }

    /// The package or checkout a running server was started from, read from its argv:
    /// `…/<root>/server/server.py` once serving, `…/<root>/install/launcher.py` while preparing.
    public static func runningRoot(arguments: [String]) -> URL? {
        for argument in arguments {
            for suffix in ["/server/server.py", "/install/launcher.py"] where argument.hasSuffix(suffix) {
                return URL(fileURLWithPath: String(argument.dropLast(suffix.count)))
            }
        }
        return nil
    }

    /// The release version of a package root; nil for a checkout.
    public static func releaseVersion(ofRoot root: URL) -> String? {
        releaseVersion(at: root.appendingPathComponent("release.json"))
    }

    static func releaseVersion(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }
}

/// Finds the Slipstream to use: `~/.local/bin/slipstream`, then `slipstream` on PATH,
/// or the configured checkout when the settings ask for one.
public enum InstallationLocator {
    public static var defaultBinDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
    }

    public static func find(config: ServerConfig, searchPath: [String],
                            binDirectory: URL = defaultBinDirectory,
                            fileManager: FileManager = .default) -> SlipstreamInstallation? {
        if config.useCheckout {
            return SlipstreamInstallation.checkout(at: config.repoURL, fileManager: fileManager)
        }
        let chosen = config.slipstreamPath.trimmingCharacters(in: .whitespaces)
        if !chosen.isEmpty, let installation = SlipstreamInstallation.at(
            executable: URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath), fileManager: fileManager) {
            return installation
        }
        let candidates = [binDirectory.path] + searchPath
        var seen = Set<String>()
        for directory in candidates where !directory.isEmpty && seen.insert(directory).inserted {
            let executable = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                .appendingPathComponent("slipstream")
            if let installation = SlipstreamInstallation.at(executable: executable, fileManager: fileManager) {
                return installation
            }
        }
        return nil
    }

    /// Every lock a running server may have written, so one started by another
    /// installation (a terminal, an earlier setting) is still found.
    public static func serveLocks(installation: SlipstreamInstallation?, config: ServerConfig) -> [URL] {
        var locks: [URL] = []
        if let installation { locks.append(installation.serveLockURL) }
        locks.append(SlipstreamInstallation.releaseDataDirectory.appendingPathComponent("runtime/serve.lock"))
        locks.append(config.serveLockURL)
        var seen = Set<String>()
        return locks.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The user's login-shell PATH: apps get a minimal one, which misses Homebrew
    /// and anything added in a shell profile.
    public static func loginShellPath(timeout: TimeInterval = 5) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n%s\\n' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return [] }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // A profile may print things first; the PATH is the last line.
        let line = text.split(separator: "\n").last.map(String.init) ?? ""
        return line.split(separator: ":").map(String.init)
    }
}

/// Release assets and their order, shared by the app's installer and its tests.
public enum ReleasePackages {
    /// The zip to install from a SHA256SUMS listing: the package built for the newest
    /// macOS major version not above this one. Returns its name and checksum.
    public static func select(from sums: String, macOSMajor: Int) -> (name: String, sha256: String)? {
        var best: (name: String, sha256: String, major: Int)?
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            let name = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard name.hasPrefix("slipstream-"), name.hasSuffix("-arm-64bit.zip"),
                  let range = name.range(of: #"-macos(\d+)-arm-64bit\.zip$"#, options: .regularExpression)
            else { continue }
            let major = Int(name[range].dropFirst("-macos".count).prefix { $0.isNumber }) ?? 0
            guard major > 0, major <= macOSMajor, major > (best?.major ?? 0) else { continue }
            best = (name, String(fields[0]), major)
        }
        return best.map { ($0.name, $0.sha256) }
    }

    /// "slipstream-26.10.0-macos26-arm-64bit" → "26.10.0".
    public static func version(fromPackageFolder name: String) -> String? {
        guard let range = name.range(of: #"^slipstream-[0-9][0-9.]*-"#, options: .regularExpression) else { return nil }
        return String(name[range].dropFirst("slipstream-".count).dropLast())
    }

    /// Version folders to delete after installing `installed`: everything but it and
    /// the newest other version. Only names of digits and dots count as versions.
    public static func superseded(_ folders: [String], installed: String) -> [String] {
        let versions = folders.filter { !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "." } && $0.first!.isNumber }
        let others = versions.filter { $0 != installed }
        guard let keep = others.max(by: isOlder) else { return [] }
        return others.filter { $0 != keep }
    }

    public static func isOlder(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(x.count, y.count) {
            let left = index < x.count ? x[index] : 0
            let right = index < y.count ? y[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
