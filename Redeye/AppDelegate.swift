import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preventer: SleepPreventer
    private(set) var statusItem: NSStatusItem!
    private lazy var settings = SettingsWindowController(preventer: preventer)

    init(preventer: SleepPreventer = SleepPreventer()) {
        self.preventer = preventer
        super.init()
    }

    private let durations: [(String, TimeInterval?)] = [
        ("Forever", nil),
        ("30 Minutes", 30 * 60),
        ("1 Hour", 60 * 60),
        ("6 Hours", 6 * 60 * 60),
        ("12 Hours", 12 * 60 * 60),
        ("24 Hours", 24 * 60 * 60),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            // Left click steps through the modes, right click (or ctrl-click) opens the menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        preventer.onChange = { [weak self] in self?.updateIcon() }
        preventer.onError = { [weak self] error in self?.showError(error) }
        updateIcon()
        LidSleepHelper.refreshRegistration()
    }

    func applicationWillTerminate(_ notification: Notification) {
        preventer.deactivate(notify: false)
    }

    // MARK: - URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    func handle(_ url: URL) {
        guard let command = URLCommand(url: url) else {
            NSLog("Redeye: ignoring unrecognized URL \(url.absoluteString)")
            return
        }
        switch command {
        case .activate(let duration, let lidClosed): preventer.activate(lidClosed ? .lidClosed : .awake, for: duration)
        case .deactivate: preventer.deactivate()
        case .toggle: preventer.toggle()
        }
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if wantsMenu {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
        } else {
            preventer.cycle()
        }
    }

    // Detach the menu after it closes so left click goes back to cycling.
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    /// Outline sun for Sleep Normally, yellow for Stay Awake, red for Stay Awake (Ignore Lid).
    private func updateIcon() {
        var config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let name: String
        let tooltip: String
        switch preventer.mode {
        case .off:
            name = "sun.horizon"
            tooltip = "Redeye: Sleep Normally"
        case .awake:
            name = "sun.horizon.fill"
            tooltip = "Redeye: Stay Awake"
            config = config.applying(.init(paletteColors: [.systemYellow]))
        case .lidClosed:
            name = "sun.horizon.fill"
            tooltip = "Redeye: Stay Awake (Ignore Lid)"
            config = config.applying(.init(paletteColors: [.systemRed]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        image?.isTemplate = preventer.mode == .off
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip
    }

    private func showError(_ error: Error) {
        let needsApproval = if case LidSleepError.needsApproval = error { true } else { false }
        let alert = NSAlert()
        alert.messageText = needsApproval ? "Allow Redeye in System Settings" : "Stay Awake (Ignore Lid) stopped"
        alert.informativeText = error.localizedDescription
        if needsApproval {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        }
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if alert.runModal() == .alertFirstButtonReturn, needsApproval {
            LidSleepHelper.openLoginItemsSettings()
        }
    }

    // MARK: - Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if preventer.isActive {
            menu.addItem(item("Sleep Normally", #selector(allowSleep)))
        }

        menu.addItem(durationsItem("Stay Awake", #selector(activateForDuration(_:))))
        menu.addItem(durationsItem("Stay Awake (Ignore Lid)", #selector(activateLidClosedForDuration(_:))))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(item("Quit Redeye", #selector(quit), key: "q"))
        return menu
    }

    private func durationsItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, (title, _)) in durations.enumerated() {
            let sub = item(title, action)
            sub.tag = index
            submenu.addItem(sub)
        }
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func statusText() -> String {
        guard preventer.isActive else { return "Sleeping Normally" }
        let awake = preventer.mode == .lidClosed ? "Staying Awake (Ignoring Lid)" : "Staying Awake"
        guard let expiresAt = preventer.expiresAt else { return "\(awake) Forever" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(awake) Until \(formatter.string(from: expiresAt))"
    }

    // MARK: - Actions

    @objc private func allowSleep() {
        preventer.deactivate()
    }

    @objc private func activateForDuration(_ sender: NSMenuItem) {
        preventer.activate(.awake, for: durations[sender.tag].1)
    }

    @objc private func activateLidClosedForDuration(_ sender: NSMenuItem) {
        preventer.activate(.lidClosed, for: durations[sender.tag].1)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
