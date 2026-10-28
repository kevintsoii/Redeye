import AppKit
import ServiceManagement

/// The Settings window: toolbar tabs for set-and-forget options. Quick actions stay in the menu.
final class SettingsWindowController: NSWindowController {
    convenience init(preventer: SleepPreventer) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab(GeneralSettingsViewController(), "General", "gearshape"))
        tabs.addTabViewItem(Self.tab(StayAwakeSettingsViewController(preventer: preventer), "Stay Awake", "sun.horizon"))
        tabs.addTabViewItem(Self.tab(AboutViewController(), "About", "info.circle"))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    private static func tab(_ controller: NSViewController, _ label: String, _ symbol: String) -> NSTabViewItem {
        controller.title = label  // NSTabViewController shows the selected tab's title in the window
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    /// Menu bar apps aren't active by default, so activate first or the window opens behind others.
    func show() {
        if window?.isVisible == false { window?.center() }
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - General

final class GeneralSettingsViewController: NSViewController {
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)

    override func loadView() {
        launchAtLogin.target = self
        launchAtLogin.action = #selector(toggleLaunchAtLogin)

        view = paddedStack([launchAtLogin, hint("Works best when Redeye.app is in /Applications.")], width: 420)
        preferredContentSize = view.fittingSize
    }

    // Launch at Login can also be changed in System Settings, so re-read it each time.
    override func viewWillAppear() {
        super.viewWillAppear()
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nTry moving Redeye.app to /Applications first."
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

// MARK: - Stay Awake

final class StayAwakeSettingsViewController: NSViewController {
    private let preventer: SleepPreventer
    private let keepDisplayOn = NSButton(checkboxWithTitle: "Keep screen on while staying awake", target: nil, action: nil)

    init(preventer: SleepPreventer) {
        self.preventer = preventer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        keepDisplayOn.target = self
        keepDisplayOn.action = #selector(toggleKeepDisplayOn)

        view = paddedStack([keepDisplayOn, hint("When on, the screen doesn't sleep due to inactivity.")], width: 420)
        preferredContentSize = view.fittingSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        keepDisplayOn.state = preventer.keepDisplayOn ? .on : .off
    }

    @objc private func toggleKeepDisplayOn() {
        preventer.keepDisplayOn = keepDisplayOn.state == .on
    }
}

// MARK: - About

final class AboutViewController: NSViewController {
    override func loadView() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Redeye")
        name.font = .boldSystemFont(ofSize: 16)

        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.textColor = .secondaryLabelColor

        let blurb = NSTextField(wrappingLabelWithString:
            "Keeps your Mac awake so long-running work, like a Claude session, keeps going while you're away.")
        blurb.alignment = .center
        blurb.preferredMaxLayoutWidth = 380

        let stack = paddedStack([icon, name, versionLabel, blurb], width: 420)
        (stack.subviews.first as? NSStackView)?.alignment = .centerX
        view = stack
        preferredContentSize = view.fittingSize
    }
}

// MARK: - Layout

/// Small gray explanatory text under a setting.
private func hint(_ text: String) -> NSTextField {
    let hint = NSTextField(wrappingLabelWithString: text)
    hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    hint.textColor = .secondaryLabelColor
    hint.preferredMaxLayoutWidth = 380
    return hint
}

/// A vertical stack with standard window padding, at a fixed content width.
private func paddedStack(_ views: [NSView], width: CGFloat) -> NSView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        container.widthAnchor.constraint(equalToConstant: width),
    ])
    return container
}
