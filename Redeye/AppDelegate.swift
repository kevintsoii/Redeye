import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preventer = SleepPreventer()
    private(set) var statusItem: NSStatusItem!
    private lazy var settings = SettingsWindowController()

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
            // Left click toggles, right click (or ctrl-click) opens the menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        preventer.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        preventer.deactivate(notify: false)
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if wantsMenu {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
        } else {
            preventer.toggle()
        }
    }

    // Detach the menu after it closes so left click goes back to toggling.
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func updateIcon() {
        let name = preventer.isActive ? "sun.horizon.fill" : "sun.horizon"
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Redeye")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = preventer.isActive
            ? "Redeye: keeping your Mac awake"
            : "Redeye: sleep allowed"
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
            menu.addItem(item("Allow Sleep", #selector(allowSleep)))
        }

        let activateItem = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, (title, _)) in durations.enumerated() {
            let sub = item(title, #selector(activateForDuration(_:)))
            sub.tag = index
            submenu.addItem(sub)
        }
        activateItem.submenu = submenu
        menu.addItem(activateItem)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(item("Quit Redeye", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func statusText() -> String {
        guard preventer.isActive else { return "Sleep allowed" }
        guard let expiresAt = preventer.expiresAt else { return "Awake indefinitely" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Awake until \(formatter.string(from: expiresAt))"
    }

    // MARK: - Actions

    @objc private func allowSleep() {
        preventer.deactivate()
    }

    @objc private func activateForDuration(_ sender: NSMenuItem) {
        preventer.activate(for: durations[sender.tag].1)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
