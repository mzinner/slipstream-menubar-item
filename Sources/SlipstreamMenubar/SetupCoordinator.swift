import AppKit
import Combine
import SlipstreamMenubarCore

/// The first-run setup's state and actions. Owned by the app, not the window: a model
/// download keeps running when the window is closed, and the window reopens where it was.
@MainActor
final class SetupCoordinator: ObservableObject {
    /// A model choice: a manifest entry, or a folder of the user's own.
    enum Selection: Equatable {
        case entry(String)
        case folder(URL)
    }

    enum Engine {
        case notInstalled
        case installing(fraction: Double?, status: String)
        case installed(SlipstreamInstallation)
        case failed(String)
    }

    @Published var step: SetupStep = .welcome
    @Published private(set) var latestVersion: String?
    @Published var pickError: String?
    @Published var selection: Selection
    @Published var modelError: String?
    @Published private(set) var checkingDisk = false
    @Published private(set) var downloader: ModelDownloader?
    @Published var startError: String?
    @Published private(set) var starting = false

    let manifest = ModelManifest.bundled
    let server: ServerController
    private var installer: ReleaseInstaller?
    private let saveConfig: (ServerConfig) -> Void
    /// Starts the server; returns why it could not, or nil.
    private let startServer: () -> String?
    private let openSettings: () -> Void
    /// Closes the window.
    var close: () -> Void = {}
    private var observers: Set<AnyCancellable> = []
    private var startWatch: Task<Void, Never>?

    init(server: ServerController, saveConfig: @escaping (ServerConfig) -> Void,
         startServer: @escaping () -> String?, openSettings: @escaping () -> Void) {
        self.server = server
        self.saveConfig = saveConfig
        self.startServer = startServer
        self.openSettings = openSettings
        selection = .entry(ModelManifest.bundled.defaultEntry?.id ?? "")
        forward(server)
    }

    /// Re-publishes a helper's changes, so the views follow them.
    private func forward<T: ObservableObject>(_ object: T) where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        object.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
    }

    // MARK: Opening

    var modelPresent: Bool { ModelPresence.isAvailable(server.config.model) }

    var isNeeded: Bool {
        SetupProgress.isNeeded(config: server.config, hasInstallation: server.installation != nil,
                               modelPresent: modelPresent)
    }

    /// Picks up at the first incomplete step, with the configured model selected.
    func prepareToShow() {
        if downloader?.phase.isRunning != true {
            step = SetupProgress.firstIncompleteStep(hasInstallation: server.installation != nil,
                                                     modelPresent: modelPresent)
        }
        let model = server.config.model.trimmingCharacters(in: .whitespaces)
        if let entry = manifest.models.first(where: { $0.repository == model && $0.isAvailable }) {
            selection = .entry(entry.id)
        } else if model.hasPrefix("/") || model.hasPrefix("~") {
            selection = .folder(URL(fileURLWithPath: (model as NSString).expandingTildeInPath))
        }
        startError = nil
        if latestVersion == nil, server.installation == nil {
            Task { latestVersion = await ReleaseInstaller(repository: server.config.releaseRepository).latestVersion() }
        }
    }

    /// Nothing is missing: setup is done without being shown.
    func completeSilently() {
        guard !server.config.setupCompleted else { return }
        markComplete()
    }

    private func markComplete() {
        var config = server.config
        config.setupCompleted = true
        saveConfig(config)
    }

    // MARK: Slipstream

    var engine: Engine {
        if let installer {
            switch installer.phase {
            case .resolving:
                return .installing(fraction: nil, status: "Starting download…")
            case .downloading(let received, let total):
                let fraction = total > 0 ? Double(received) / Double(total) : nil
                return .installing(fraction: fraction,
                                   status: fraction.map { "Downloading \(Int($0 * 100)) %" } ?? "Downloading…")
            case .verifying:
                return .installing(fraction: 1, status: "Verifying…")
            case .unpacking:
                return .installing(fraction: 1, status: "Installing…")
            case .failed(let message):
                return .failed(message)
            case .idle, .done, .cancelled:
                break
            }
        }
        if let installation = server.installation { return .installed(installation) }
        return .notInstalled
    }

    /// Install was clicked in this setup (the progress bar shows from then on).
    var installStarted: Bool { installer != nil }

    var engineVersion: String {
        if let installation = server.installation { return installation.version ?? "checkout" }
        return installer?.releaseName.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            ?? latestVersion ?? "—"
    }

    var engineLocation: String {
        let url = server.installation?.root ?? ReleaseInstaller.prefix
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    func install() {
        pickError = nil
        // The release goes to ~/.local, where the app looks first once no other choice is set.
        var config = server.config
        if config.useCheckout || !config.slipstreamPath.isEmpty {
            config.useCheckout = false
            config.slipstreamPath = ""
            saveConfig(config)
        }
        let installer = ReleaseInstaller(repository: server.config.releaseRepository)
        self.installer = installer
        forward(installer)
        installer.start { [weak self] _ in self?.server.locate() }
    }

    /// "Already installed? Use existing installation…"
    func chooseExisting() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder where Slipstream is installed, or its slipstream command."
        panel.prompt = "Use"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = ReleaseInstaller.prefix
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch SlipstreamInstallation.chosen(url) {
        case .success(let installation):
            pickError = nil
            installer = nil
            saveConfig(installation.applied(to: server.config))
            server.locate()
        case .failure(let error):
            pickError = error.localizedDescription
        }
    }

    // MARK: Model

    var selectedEntry: ModelManifest.Entry? {
        if case .entry(let id) = selection { return manifest.entry(id: id) }
        return nil
    }

    /// The chosen model's name, for the server step.
    var modelName: String {
        switch selection {
        case .entry(let id): return manifest.entry(id: id)?.name ?? id
        case .folder(let url): return url.lastPathComponent
        }
    }

    func select(_ entry: ModelManifest.Entry) {
        guard entry.isAvailable else { return }
        modelError = nil
        selection = .entry(entry.id)
    }

    /// "Other model": a folder of GGUF files or a prepared package. Cancel keeps the
    /// previous choice.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder with a model's GGUF files or a prepared Slipstream package."
        panel.prompt = "Use"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ModelPresence.isAvailable(url.path) else {
            modelError = "\(url.lastPathComponent) holds no GGUF files or prepared package. "
                + "Choose the folder the model's files are in."
            return
        }
        modelError = nil
        selection = .folder(url)
    }

    /// Already on disk: "Continue" rather than "Download and continue".
    var selectionIsOnDisk: Bool {
        switch selection {
        case .folder: return true
        case .entry(let id):
            guard let repository = manifest.entry(id: id)?.repository else { return false }
            return ModelStore.isDownloaded(repository)
        }
    }

    /// Starts the download (unless the model is on disk) and moves on; it continues in
    /// the background. The model becomes the configured one at once, so a reopened setup
    /// resumes with it.
    func downloadAndContinue() {
        modelError = nil
        switch selection {
        case .folder(let url):
            use(model: url.path)
            step = .server
        case .entry(let id):
            guard let spec = manifest.entry(id: id)?.spec else { return }
            use(model: spec.repository)
            if ModelStore.isDownloaded(spec.repository) || downloader?.model == spec && downloader?.phase.isRunning == true {
                step = .server
                return
            }
            guard let installation = server.installation else {
                modelError = "Slipstream is not installed: go back and install it first."
                return
            }
            Task { await checkDiskAndDownload(spec, installation: installation) }
        }
    }

    private func use(model: String) {
        guard server.config.model != model else { return }
        var config = server.config
        config.model = model
        saveConfig(config)
    }

    private func checkDiskAndDownload(_ spec: ModelSpec, installation: SlipstreamInstallation) async {
        checkingDisk = true
        defer { checkingDisk = false }
        let downloader = ModelDownloader(model: spec, installation: installation, searchPath: server.searchPath)
        guard let total = try? await ModelDownloader.totalSize(of: spec) else {
            modelError = "Hugging Face could not be reached to check \(spec.title)'s size. Try again later."
            return
        }
        let free = MachineCheck.freeDiskBytes(at: spec.folderURL) ?? 0
        let preparation: DiskCheck.Preparation = spec.kind != .gguf ? .none
            : installation.supportsKeepGGUF && !server.config.keepGGUFFiles ? .inPlace : .alongside
        if case .insufficient(let shortBy) = DiskCheck.evaluate(total: total, downloaded: downloader.downloadedBytes,
                                                                free: free, preparation: preparation) {
            modelError = "\(spec.title) needs \(bytes(total)), and \(bytes(DiskCheck.reserveBytes)) must stay free. "
                + "Make \(bytes(shortBy)) more room, then try again."
            return
        }
        if let previous = self.downloader, previous.phase.isRunning { previous.abort() }
        self.downloader = downloader
        forward(downloader)
        downloader.run { _ in }
        step = .server
    }

    func retryDownload() {
        guard let downloader, !downloader.phase.isRunning else { return }
        downloader.run { _ in }
    }

    var isDownloading: Bool { downloader?.phase.isRunning == true }

    /// Quitting stops a running download; its partial files stay for the next one.
    func confirmQuit() -> Bool {
        guard let downloader, downloader.phase.isRunning else { return true }
        let alert = NSAlert()
        alert.messageText = "A model download is running"
        alert.informativeText = "Quitting stops it. The \(bytes(downloader.downloadedBytes)) downloaded so far stay "
            + "in \(downloader.model.folder), and setup continues from there next time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Downloading")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        downloader.stopForQuit()
        return true
    }

    // MARK: Server

    var endpoint: String { "http://localhost:\(server.config.port)" }

    /// Starts the server; setup is complete once it is preparing, loading or running.
    /// A failure keeps the window open with the reason.
    func start() {
        startError = nil
        if let reason = startServer() {
            startError = reason
            return
        }
        starting = true
        startWatch?.cancel()
        startWatch = Task { [weak self] in
            while let self, !Task.isCancelled {
                switch self.server.status {
                case .preparing, .loading, .running:
                    self.starting = false
                    self.markComplete()
                    self.close()
                    return
                case .failed(let reason):
                    self.starting = false
                    self.startError = reason
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    func openSettingsInstead() {
        markComplete()
        close()
        openSettings()
    }

    func stopWatchingStart() {
        startWatch?.cancel()
        starting = false
    }
}

private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
