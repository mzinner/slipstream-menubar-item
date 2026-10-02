import Foundation

/// The settings the app starts `slipstream serve` with.
///
/// The API key is not part of this file: it lives in the Keychain and reaches the
/// server through its environment, never its command line.
public struct ServerConfig: Codable, Equatable, Sendable {
    /// The Slipstream source checkout that holds the `slipstream` launcher.
    public var repoPath: String
    /// A local model directory (GGUF shards or a prepared package) or a Hub repo id.
    public var model: String
    public var port: Int
    /// e.g. "100K"; empty means the server's automatic choice.
    public var maxContext: String
    /// e.g. "48G"; empty means the server's automatic choice.
    public var maxMemory: String
    public var allowedHosts: [String]
    public var noWebUI: Bool
    /// Listen on all interfaces (`--host 0.0.0.0`) instead of 127.0.0.1 only.
    public var listenOnNetwork: Bool
    /// Start the server when the app launches if it is not already running.
    public var startServerOnLaunch: Bool

    public init(
        repoPath: String = ServerConfig.defaultRepoPath(),
        model: String = "",
        port: Int = 8090,
        maxContext: String = "",
        maxMemory: String = "",
        allowedHosts: [String] = [],
        noWebUI: Bool = false,
        listenOnNetwork: Bool = false,
        startServerOnLaunch: Bool = false
    ) {
        self.repoPath = repoPath
        self.model = model
        self.port = port
        self.maxContext = maxContext
        self.maxMemory = maxMemory
        self.allowedHosts = allowedHosts
        self.noWebUI = noWebUI
        self.listenOnNetwork = listenOnNetwork
        self.startServerOnLaunch = startServerOnLaunch
    }

    /// Settings saved by an older version lack newer keys; those take their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfig()
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath) ?? defaults.repoPath
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        maxContext = try container.decodeIfPresent(String.self, forKey: .maxContext) ?? defaults.maxContext
        maxMemory = try container.decodeIfPresent(String.self, forKey: .maxMemory) ?? defaults.maxMemory
        allowedHosts = try container.decodeIfPresent([String].self, forKey: .allowedHosts) ?? defaults.allowedHosts
        noWebUI = try container.decodeIfPresent(Bool.self, forKey: .noWebUI) ?? defaults.noWebUI
        listenOnNetwork = try container.decodeIfPresent(Bool.self, forKey: .listenOnNetwork)
            ?? defaults.listenOnNetwork
        startServerOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .startServerOnLaunch)
            ?? defaults.startServerOnLaunch
    }

    /// The address `--host` gets.
    public var host: String { listenOnNetwork ? "0.0.0.0" : "127.0.0.1" }

    public static func defaultRepoPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("git/slipstream").path
    }

    public var repoURL: URL { URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath) }
    public var launcherURL: URL { repoURL.appendingPathComponent("slipstream") }
    public var serveLockURL: URL { repoURL.appendingPathComponent("build/runtime/serve.lock") }

    /// Arguments after the launcher path.
    public func serveArguments() -> [String] {
        var arguments = ["serve", "--model", (model as NSString).expandingTildeInPath, "--port", String(port)]
        // The default needs no flag, which keeps launchers without --host working.
        if listenOnNetwork { arguments += ["--host", host] }
        let context = maxContext.trimmingCharacters(in: .whitespaces)
        if !context.isEmpty { arguments += ["--max-context", context] }
        let memory = maxMemory.trimmingCharacters(in: .whitespaces)
        if !memory.isEmpty { arguments += ["--max-memory", memory] }
        for host in allowedHosts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !host.isEmpty {
            arguments += ["--allowed-host", host]
        }
        if noWebUI { arguments.append("--no-webui") }
        return arguments
    }

    /// Whether the checkout's launcher accepts `serve --host` (npanj/slipstream#5).
    public func launcherSupportsHost(fileManager: FileManager = .default) -> Bool {
        let launcher = repoURL.appendingPathComponent("install/launcher.py")
        guard let source = try? String(contentsOf: launcher, encoding: .utf8) else { return false }
        return source.contains("\"--host\"")
    }

    /// Problems that would make `slipstream serve` fail immediately, for the settings window.
    public func validationErrors(fileManager: FileManager = .default) -> [String] {
        var errors: [String] = []
        if !fileManager.isExecutableFile(atPath: launcherURL.path) {
            errors.append("No `slipstream` launcher in \(repoURL.path)")
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("No model selected")
        }
        if listenOnNetwork, !launcherSupportsHost(fileManager: fileManager) {
            errors.append("Listening on the network needs a Slipstream checkout whose launcher has `serve --host`")
        }
        if !(1...65535).contains(port) {
            errors.append("Port must be between 1 and 65535")
        }
        let size = #"^\s*$|^\s*(auto|\d+(\.\d+)?\s*[KkMmGg]?)\s*$"#
        if maxContext.range(of: size, options: .regularExpression) == nil {
            errors.append("Max context must look like 100K or be empty")
        }
        if maxMemory.range(of: size, options: .regularExpression) == nil {
            errors.append("Max memory must look like 48G or be empty")
        }
        return errors
    }
}

/// Loads and saves the configuration as JSON in Application Support.
public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = ConfigStore.defaultURL()) {
        self.url = url
    }

    /// `SLIPSTREAM_MENUBAR_CONFIG` points a test instance at another file.
    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SLIPSTREAM_MENUBAR_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Slipstream/menubar.json")
    }

    public func load() -> ServerConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ServerConfig.self, from: data) else {
            return ServerConfig()
        }
        return config
    }

    public func save(_ config: ServerConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
