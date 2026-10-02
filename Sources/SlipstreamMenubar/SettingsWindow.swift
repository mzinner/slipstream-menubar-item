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

    init(server: ServerController, save: @escaping (ServerConfig, String?, Bool) -> Void) {
        self.server = server
        self.save = save
    }

    func show() {
        // A fresh form each time, so it always starts from the saved values.
        let view = SettingsView(
            config: server.config, apiKey: server.apiKey ?? "", serverActive: server.status.isActive,
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
    let onSave: (ServerConfig, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var allowedHosts = ""
    @State private var port = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    init(config: ServerConfig, apiKey: String, serverActive: Bool,
         onSave: @escaping (ServerConfig, String, Bool) -> Void, onCancel: @escaping () -> Void) {
        _config = State(initialValue: config)
        _apiKey = State(initialValue: apiKey)
        _allowedHosts = State(initialValue: config.allowedHosts.joined(separator: ", "))
        _port = State(initialValue: String(config.port))
        self.serverActive = serverActive
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var edited: ServerConfig {
        var result = config
        result.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 0
        result.allowedHosts = allowedHosts.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return result
    }

    var body: some View {
        let errors = edited.validationErrors()
        VStack(alignment: .leading, spacing: 0) {
            Form {
                SwiftUI.Section("Server") {
                    PathField(label: "Slipstream checkout", path: $config.repoPath, directoriesOnly: true)
                    PathField(label: "Model", path: $config.model, directoriesOnly: true,
                              help: "A folder with GGUF shards or a prepared package, or a Hub repo id")
                    TextField("Port", text: $port)
                    TextField("Max context", text: $config.maxContext, prompt: Text("auto, e.g. 100K"))
                    TextField("Max memory", text: $config.maxMemory, prompt: Text("auto, e.g. 48G"))
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
