import AppKit
import XCTest
@testable import Redeye

@MainActor
final class AppDelegateTests: XCTestCase {
    /// A delegate that hasn't launched, so it has no status item. Enough for the menu.
    private lazy var delegate: AppDelegate = {
        let delegate = AppDelegate()
        addTeardownBlock { @MainActor in delegate.preventer.deactivate(notify: false) }
        return delegate
    }()

    /// A delegate that has launched, with its own (temporary) status item.
    private func launchedDelegate() -> AppDelegate {
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let item = delegate.statusItem!
        addTeardownBlock { @MainActor in NSStatusBar.system.removeStatusItem(item) }
        return delegate
    }

    // MARK: - Menu

    func testMenuWhenSleepAllowed() {
        XCTAssertEqual(titles(of: delegate.buildMenu()), [
            "Sleep allowed", "---",
            "Keep Awake", "---",
            "Settings…", "---",
            "Quit Redeye",
        ])
    }

    func testMenuWhenAwake() {
        delegate.preventer.activate()
        XCTAssertEqual(titles(of: delegate.buildMenu()), [
            "Awake indefinitely", "---",
            "Allow Sleep",
            "Keep Awake", "---",
            "Settings…", "---",
            "Quit Redeye",
        ])
    }

    func testStatusLineIsDisabled() {
        let status = delegate.buildMenu().items[0]
        XCTAssertFalse(status.isEnabled)
        XCTAssertNil(status.action)
    }

    func testDurationsSubmenu() throws {
        let submenu = try XCTUnwrap(item("Keep Awake", in: delegate.buildMenu()).submenu)
        XCTAssertEqual(titles(of: submenu), ["Forever", "30 Minutes", "1 Hour", "6 Hours", "12 Hours", "24 Hours"])
    }

    func testKeyEquivalents() throws {
        let menu = delegate.buildMenu()
        XCTAssertEqual(try item("Settings…", in: menu).keyEquivalent, ",")
        XCTAssertEqual(try item("Quit Redeye", in: menu).keyEquivalent, "q")
    }

    func testEveryActionableItemIsWired() throws {
        delegate.preventer.activate()
        let menu = delegate.buildMenu()
        let submenu = try XCTUnwrap(item("Keep Awake", in: menu).submenu)
        // Items with a submenu get AppKit's own submenuAction:, so skip those.
        let actionable = (menu.items + submenu.items).filter { $0.action != nil && !$0.hasSubmenu }
        XCTAssertEqual(actionable.count, 3 + 6)  // Allow Sleep, Settings, Quit + durations
        for menuItem in actionable {
            XCTAssertTrue(menuItem.target === delegate, menuItem.title)
            XCTAssertTrue(delegate.responds(to: menuItem.action), menuItem.title)
        }
    }

    func testMenuDelegateIsSet() {
        XCTAssertTrue(delegate.buildMenu().delegate === delegate)
    }

    // MARK: - Menu actions

    func testDurationItemsActivateForTheirDuration() throws {
        let expected: [String: TimeInterval?] = [
            "Forever": nil,
            "30 Minutes": 30 * 60,
            "1 Hour": 60 * 60,
            "6 Hours": 6 * 60 * 60,
            "12 Hours": 12 * 60 * 60,
            "24 Hours": 24 * 60 * 60,
        ]
        for (title, duration) in expected {
            delegate.preventer.deactivate(notify: false)
            let submenu = try XCTUnwrap(item("Keep Awake", in: delegate.buildMenu()).submenu)
            try perform(item(title, in: submenu))

            XCTAssertTrue(delegate.preventer.isActive, title)
            if let duration {
                let expiresAt = try XCTUnwrap(delegate.preventer.expiresAt, title)
                XCTAssertEqual(expiresAt.timeIntervalSinceNow, duration, accuracy: 2, title)
            } else {
                XCTAssertNil(delegate.preventer.expiresAt, title)
            }
        }
        XCTAssertEqual(redeyeAssertionCount(), 1)
    }

    func testAllowSleepItemDeactivates() throws {
        delegate.preventer.activate(for: 60)
        try perform(item("Allow Sleep", in: delegate.buildMenu()))
        XCTAssertFalse(delegate.preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    // MARK: - Status text

    func testStatusTextWhenSleepAllowed() {
        XCTAssertEqual(delegate.statusText(), "Sleep allowed")
    }

    func testStatusTextWhenIndefinite() {
        delegate.preventer.activate()
        XCTAssertEqual(delegate.statusText(), "Awake indefinitely")
    }

    func testStatusTextWhenTimed() throws {
        delegate.preventer.activate(for: 60 * 60)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let expiresAt = try XCTUnwrap(delegate.preventer.expiresAt)
        XCTAssertEqual(delegate.statusText(), "Awake until \(formatter.string(from: expiresAt))")
    }

    // MARK: - Status item

    func testLaunchCreatesStatusItem() throws {
        let button = try XCTUnwrap(launchedDelegate().statusItem.button)
        XCTAssertTrue(button.target === delegate)
        XCTAssertNotNil(button.action)
        XCTAssertNil(delegate.statusItem.menu, "left click should toggle, not open a menu")
    }

    func testIconFollowsState() throws {
        let button = try XCTUnwrap(launchedDelegate().statusItem.button)
        let image = try XCTUnwrap(button.image)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(button.toolTip, "Redeye: sleep allowed")

        delegate.preventer.toggle()
        XCTAssertEqual(button.toolTip, "Redeye: keeping your Mac awake")
        XCTAssertNotEqual(button.image?.tiffRepresentation, image.tiffRepresentation, "active icon should differ")

        delegate.preventer.toggle()
        XCTAssertEqual(button.toolTip, "Redeye: sleep allowed")
    }

    func testIconResetsWhenTimerExpires() throws {
        let button = try XCTUnwrap(launchedDelegate().statusItem.button)
        delegate.preventer.activate(for: 0.2)
        XCTAssertEqual(button.toolTip, "Redeye: keeping your Mac awake")
        runMainLoop(for: 0.6)
        XCTAssertEqual(button.toolTip, "Redeye: sleep allowed")
    }

    func testMenuDetachesWhenClosed() {
        let launched = launchedDelegate()
        let menu = launched.buildMenu()
        launched.statusItem.menu = menu
        launched.menuDidClose(menu)
        XCTAssertNil(launched.statusItem.menu)
    }

    // MARK: - Quitting

    func testQuittingRestoresSleep() {
        delegate.preventer.activate()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(delegate.preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testQuittingDuringTimedSessionRestoresSleep() {
        delegate.preventer.activate(for: 60)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(delegate.preventer.isActive)
        XCTAssertNil(delegate.preventer.expiresAt)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    // MARK: - Helpers

    /// Item titles, with "---" for separators.
    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.item(withTitle: title), "no menu item \"\(title)\"")
    }

    /// Sends the item's action to its target, like choosing it in the menu.
    private func perform(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), item.title)
    }
}
