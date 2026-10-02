import AppKit
import SlipstreamMenubarCore

/// The status item and its menu:
///
///   ● Status · model · :port     (not clickable)
///   Start Server / Stop Server / Force Stop
///   ─────
///   Stats Panel
///   ─────
///   Settings…  ⌘,
///   About Slipstream Menubar
///   ─────
///   Quit  ⌘Q
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let server: ServerController
    private let actions: Actions

    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var forceStopItem: NSMenuItem!
    private var panelItem: NSMenuItem!

    struct Actions {
        var start: () -> Void
        var stop: () -> Void
        var forceStop: () -> Void
        var togglePanel: () -> Void
        var isPanelVisible: () -> Bool
        var settings: () -> Void
        var about: () -> Void
        var menuOpened: (Bool) -> Void
    }

    init(server: ServerController, actions: Actions) {
        self.server = server
        self.actions = actions
        super.init()
        build()
        update()
    }

    private func build() {
        menu.delegate = self
        menu.autoenablesItems = false
        headerItem.isEnabled = false
        detailItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())
        startItem = add("Start Server", #selector(start))
        stopItem = add("Stop Server", #selector(stop))
        forceStopItem = add("Force Stop", #selector(forceStop))
        menu.addItem(.separator())
        panelItem = add("Stats Panel", #selector(togglePanel), key: "s")
        menu.addItem(.separator())
        add("Settings…", #selector(settings), key: ",")
        add("About Slipstream Menubar", #selector(about))
        menu.addItem(.separator())
        add("Quit", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func update() {
        let status = server.status
        let running = status == .running
        let symbol = running ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Slipstream \(status.title)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !status.isActive

        let header = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: status.color, .font: NSFont.menuFont(ofSize: 0)])
        header.append(NSAttributedString(
            string: status.title + (server.external && status.isActive ? " (started elsewhere)" : ""),
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.boldSystemFont(ofSize: 0)]))
        headerItem.attributedTitle = header

        var detail: [String] = []
        if let model = server.model { detail.append((model as NSString).lastPathComponent) }
        if status.isActive { detail.append(server.listensOnNetwork ? "network :\(server.port)" : ":\(server.port)") }
        if case .failed(let message) = status { detail.append(message) }
        detailItem.title = detail.joined(separator: " · ")
        detailItem.isHidden = detail.isEmpty

        startItem.isHidden = status.isActive
        stopItem.isHidden = !status.isActive
        stopItem.isEnabled = status != .stopping
        forceStopItem.isHidden = !(status == .unresponsive || status == .stopping)
        panelItem.state = actions.isPanelVisible() ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        actions.menuOpened(true)
        update()
    }

    func menuDidClose(_ menu: NSMenu) {
        actions.menuOpened(false)
    }

    @objc private func start() { actions.start() }
    @objc private func stop() { actions.stop() }
    @objc private func forceStop() { actions.forceStop() }
    @objc private func togglePanel() { actions.togglePanel() }
    @objc private func settings() { actions.settings() }
    @objc private func about() { actions.about() }
    @objc private func quit() { NSApp.terminate(nil) }
}
