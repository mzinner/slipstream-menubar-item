import AppKit
import ServiceManagement
import SlipstreamMenubarCore
import SwiftUI

/// The settings window: the core `slipstream serve` options and app behaviour.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let server: ServerController
    private let save: (ServerConfig, String?, _ restart: Bool) -> Void
    private let install: () -> Void
    private let downloadModel: (ModelSpec?) -> Void
    private let uninstall: () -> Void

    /// `downloadModel(nil)` opens the download window at New Model…
    init(server: ServerController, save: @escaping (ServerConfig, String?, Bool) -> Void,
         install: @escaping () -> Void, downloadModel: @escaping (ModelSpec?) -> Void,
         uninstall: @escaping () -> Void) {
        self.server = server
        self.save = save
        self.install = install
        self.downloadModel = downloadModel
        self.uninstall = uninstall
    }

    func show() {
        // A fresh form each time, so it always starts from the saved values.
        let view = SettingsView(
            config: server.config, apiKey: server.apiKey ?? "", serverActive: server.status.isActive,
            server: server,
            install: install,
            downloadModel: downloadModel,
            uninstall: { [weak self] in
                self?.window?.close()
                self?.uninstall()
            },
            onSave: { [weak self] config, key, restart in
                self?.save(config, key.isEmpty ? nil : key, restart)
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() })
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Slipstream Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @State var config: ServerConfig
    @State var apiKey: String
    let serverActive: Bool
    /// Observed so the installation shown follows an install or update made while the
    /// window is open.
    @ObservedObject var server: ServerController
    let install: () -> Void
    let downloadModel: (ModelSpec?) -> Void
    let uninstall: () -> Void
    let onSave: (ServerConfig, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var allowedHosts = ""
    @State private var port = ""
    @State private var gpuLimit = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    init(config: ServerConfig, apiKey: String, serverActive: Bool,
         server: ServerController, install: @escaping () -> Void,
         downloadModel: @escaping (ModelSpec?) -> Void, uninstall: @escaping () -> Void,
         onSave: @escaping (ServerConfig, String, Bool) -> Void, onCancel: @escaping () -> Void) {
        _config = State(initialValue: config)
        _apiKey = State(initialValue: apiKey)
        _allowedHosts = State(initialValue: config.allowedHosts.joined(separator: ", "))
        _port = State(initialValue: String(config.port))
        _gpuLimit = State(initialValue: String(config.gpuWiredLimitMB))
        self.serverActive = serverActive
        self.server = server
        self.install = install
        self.downloadModel = downloadModel
        self.uninstall = uninstall
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var edited: ServerConfig {
        var result = config
        result.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 0
        result.gpuWiredLimitMB = Int(gpuLimit.trimmingCharacters(in: .whitespaces)) ?? 0
        result.allowedHosts = allowedHosts.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return result
    }

    var body: some View {
        let installation = server.installation(for: edited)
        let errors = edited.validationErrors(installation: installation)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                SwiftUI.Section("Server") {
                    Picker("Run", selection: $config.useCheckout) {
                        Text("Installed release").tag(false)
                        Text("Source checkout").tag(true)
                    }
                    if config.useCheckout {
                        PathField(label: "Slipstream checkout", path: $config.repoPath, directoriesOnly: true)
                    } else {
                        InstalledRelease(installation: installation, install: install)
                    }
                    ModelChoice(model: $config.model, models: server.config.availableModels,
                                download: downloadModel)
                    TextField("Port", text: $port)
                    TextField("Max context", text: $config.maxContext, prompt: Text("auto, e.g. 100K"))
                    TextField("Max memory", text: $config.maxMemory, prompt: Text("auto, e.g. 48G"))
                }
                SwiftUI.Section("Memory") {
                    Toggle("Raise the GPU memory limit before starting", isOn: $config.raiseGPULimit)
                    if config.raiseGPULimit {
                        TextField("GPU memory limit (MB)", text: $gpuLimit, prompt: Text("59392"))
                    }
                    Text(gpuNote).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SwiftUI.Section("Access") {
                    HStack {
                        SecureField("API key", text: $apiKey, prompt: Text("none"))
                        Button("Generate") { apiKey = APIKeyStore.generate() }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(apiKey, forType: .string)
                        }
                        .disabled(apiKey.isEmpty)
                    }
                    Toggle("Listen on the network", isOn: $config.listenOnNetwork)
                    if config.listenOnNetwork {
                        NetworkNotes(port: port, hasKey: !apiKey.isEmpty)
                    } else {
                        Text("Only this Mac can connect (127.0.0.1).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Allowed hosts", text: $allowedHosts, prompt: Text("comma separated"))
                        Text("Extra names clients may use in URLs, e.g. this Mac's .local name. "
                             + "Addresses (127.0.0.1, its IP) always work.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Disable web UI", isOn: $config.noWebUI)
                }
                SwiftUI.Section("App") {
                    Toggle("Start the server when the app launches", isOn: $config.startServerOnLaunch)
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in setLoginItem(enabled) }
                    if let loginItemError {
                        Text(loginItemError).font(.caption).foregroundStyle(.red)
                    }
                    Text("Quitting the app leaves the server running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SwiftUI.Section("Uninstall and Cleanup") {
                    DownloadedModels(server: server)
                    HStack {
                        Text("Removes Slipstream, its command, data and logs, the models you choose, and this app.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Uninstall and Cleanup…", role: .destructive, action: uninstall)
                    }
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    if serverActive {
                        Text("Changes take effect when the server restarts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    if serverActive {
                        Button("Save") { onSave(edited, apiKey, false) }
                        Button("Save & Restart") { onSave(edited, apiKey, true) }
                            .keyboardShortcut(.defaultAction).disabled(!errors.isEmpty)
                    } else {
                        Button("Save") { onSave(edited, apiKey, false) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
    }

    /// What the GPU limit step does on this Mac.
    private var gpuNote: String {
        let current = GPUMemoryLimit.currentMB().map { $0 == 0 ? "the macOS default" : "\($0) MB" } ?? "unknown"
        let applies = MachineCheck.needsGPULimitRaise()
            ? "This Mac has \(MachineCheck.memoryGiB) GB, so it is applied before each start"
            : "This Mac has \(MachineCheck.memoryGiB) GB; it applies to 64 GB Macs only"
        return "Sets iogpu.wired_limit_mb with an administrator password when it differs (it resets at "
            + "every boot). \(applies). Now: \(current)."
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Could not change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// A text field with a Choose… button that opens a folder picker.
private struct PathField: View {
    let label: String
    @Binding var path: String
    var directoriesOnly = true
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField(label, text: $path)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = !directoriesOnly
                    panel.allowsMultipleSelection = false
                    let expanded = (path as NSString).expandingTildeInPath
                    if FileManager.default.fileExists(atPath: expanded) {
                        panel.directoryURL = URL(fileURLWithPath: expanded)
                    }
                    if panel.runModal() == .OK, let url = panel.url {
                        path = (url.path as NSString).abbreviatingWithTildeInPath
                    }
                }
            }
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Where other machines can reach the server, and a warning without an API key.
private struct NetworkNotes: View {
    let port: String
    let hasKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !hasKey {
                Label("Without an API key, anyone on your network can use the server.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            let addresses = NetworkAddresses.ipv4()
            if !addresses.isEmpty {
                Text("Other machines connect to " + addresses.map { "http://\($0):\(port)" }
                    .joined(separator: " or "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let name = NetworkAddresses.localHostName() {
                Text("To use http://\(name):\(port), add \(name) to Allowed hosts.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Traffic is not encrypted. macOS may ask whether Python may accept incoming connections.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The installed release Start would run, or a way to install one.
private struct InstalledRelease: View {
    let installation: SlipstreamInstallation?
    let install: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let installation {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installation.displayName)
                    Text(installation.launcher.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Update…", action: install)
                    .help("Install the latest release; the two newest versions are kept")
            } else {
                Text("Not installed: no `slipstream` in ~/.local/bin or on PATH.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Install…", action: install)
            }
        }
    }
}

/// The model picker: the supported models and those added with New Model…, a custom
/// folder or Hub id, or New Model… to add one.
private struct ModelChoice: View {
    @Binding var model: String
    let models: [ModelSpec]
    let download: (ModelSpec?) -> Void

    private enum Choice: Hashable {
        case model(String)  // repository
        case custom
        case new
    }

    @State private var customOpen = false

    private var selection: Binding<Choice> {
        Binding(
            get: {
                if customOpen { return .custom }
                return ModelSpec.matching(path: model, in: models).map { .model($0.repository) } ?? .custom
            },
            set: { choice in
                switch choice {
                case .model(let repository):
                    customOpen = false
                    if let spec = models.first(where: { $0.repository == repository }) { model = spec.folder }
                case .custom:
                    customOpen = true
                case .new:
                    download(nil)
                }
            })
    }

    var body: some View {
        let current = ModelSpec.matching(path: model, in: models)
        Picker("Model", selection: selection) {
            ForEach(models, id: \.repository) { spec in
                Text("\(spec.title) (\(spec.memoryNote))").tag(Choice.model(spec.repository))
            }
            Divider()
            Text("Custom folder or Hub id").tag(Choice.custom)
            Text("New Model…").tag(Choice.new)
        }
        if let current, !customOpen {
            HStack {
                Text(current.folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if ModelPresence.isAvailable(current.folder) {
                    Label("Downloaded", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not downloaded").font(.caption).foregroundStyle(.orange)
                    Button("Download…") { download(current) }
                }
            }
            if MachineCheck.memoryGiB < current.minimumMemoryGiB {
                Text("This Mac has \(MachineCheck.memoryGiB) GB of memory; this model needs a \(current.memoryNote).")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            PathField(label: "Folder or Hub id", path: $model, directoriesOnly: true,
                      help: "A folder with GGUF files or a Slipstream package, or the Hugging Face id of a "
                          + "ready-to-run Slipstream package, which the server downloads on its first start")
            if !ModelPresence.isAvailable(model) {
                Text("No model at this location.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// The downloaded models, each with its size and a Delete button.
private struct DownloadedModels: View {
    @ObservedObject var server: ServerController
    @State private var sizes: [String: Int64] = [:]
    @State private var refresh = 0

    var body: some View {
        let items = Cleanup.modelItems(models: server.config.availableModels, configuredModel: server.config.model)
        if items.isEmpty {
            Text("No downloaded models.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(items) { item in
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                    Text((item.url.path as NSString).abbreviatingWithTildeInPath + " · "
                         + (sizes[item.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete…") { delete(item) }
            }
            .task(id: item.id) {
                let url = item.url
                let size = await Task.detached { ModelPresence.allocatedSize(of: url) }.value
                sizes[item.id] = size
            }
        }
        .id(refresh)
    }

    private func delete(_ item: CleanupItem) {
        let inUse = server.isServing(folder: item.url)
        let alert = NSAlert()
        alert.messageText = "Delete \(item.title)?"
        alert.informativeText = "Removes \((item.url.path as NSString).abbreviatingWithTildeInPath)"
            + (sizes[item.id].map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? "")
            + (item.title.contains("Flash-Next") ? ", including the copy prepared on its first start" : "") + "."
            + (inUse ? " The server is running this model and is stopped first." : "")
            + " It cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: inUse ? "Stop and Delete" : "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if inUse { await server.stopAndWait() }
            do {
                try Cleanup.remove(item)
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
            refresh += 1
        }
    }
}
