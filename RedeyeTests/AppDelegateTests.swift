import AppKit
import XCTest
@testable import Redeye

@MainActor
final class AppDelegateTests: XCTestCase {
    /// A delegate that hasn't launched, so it has no status item. Enough for the menu.
    private lazy var helper = FakeSleepDisabler()
    private lazy var delegate: AppDelegate = {
        let preventer = SleepPreventer(
            defaults: makeTestDefaults(for: self), sleepDisabler: helper, powerMonitor: FakePowerMonitor())
        let delegate = AppDelegate(preventer: preventer)
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
            "Sleeping Normally", "---",
            "Stay Awake",
            "Stay Awake (Ignore Lid)", "---",
            "Settings…", "---",
            "Quit Redeye",
        ])
    }

    func testMenuWhenAwake() {
        delegate.preventer.activate()
        XCTAssertEqual(titles(of: delegate.buildMenu()), [
            "Staying Awake Forever", "---",
            "Sleep Normally",
            "Stay Awake",
            "Stay Awake (Ignore Lid)", "---",
            "Settings…", "---",
            "Quit Redeye",
        ])
    }

    func testStatusLineIsDisabled() {
        let status = delegate.buildMenu().items[0]
        XCTAssertFalse(status.isEnabled)
        XCTAssertNil(status.action)
    }

    func testDurationsSubmenus() throws {
        for parent in ["Stay Awake", "Stay Awake (Ignore Lid)"] {
            let submenu = try XCTUnwrap(item(parent, in: delegate.buildMenu()).submenu)
            XCTAssertEqual(titles(of: submenu), ["Forever", "30 Minutes", "1 Hour", "6 Hours", "12 Hours", "24 Hours"])
        }
    }

    func testKeyEquivalents() throws {
        let menu = delegate.buildMenu()
        XCTAssertEqual(try item("Settings…", in: menu).keyEquivalent, ",")
        XCTAssertEqual(try item("Quit Redeye", in: menu).keyEquivalent, "q")
    }

    func testEveryActionableItemIsWired() throws {
        delegate.preventer.activate()
        let menu = delegate.buildMenu()
        let submenu = try XCTUnwrap(item("Stay Awake", in: menu).submenu)
        let lidSubmenu = try XCTUnwrap(item("Stay Awake (Ignore Lid)", in: menu).submenu)
        // Items with a submenu get AppKit's own submenuAction:, so skip those.
        let actionable = (menu.items + submenu.items + lidSubmenu.items).filter { $0.action != nil && !$0.hasSubmenu }
        XCTAssertEqual(actionable.count, 3 + 6 + 6)  // Sleep Normally, Settings, Quit + both sets of durations
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
            let submenu = try XCTUnwrap(item("Stay Awake", in: delegate.buildMenu()).submenu)
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

    func testLidClosedDurationItemsActivateLidClosedMode() throws {
        let submenu = try XCTUnwrap(item("Stay Awake (Ignore Lid)", in: delegate.buildMenu()).submenu)
        try perform(item("1 Hour", in: submenu))
        XCTAssertEqual(delegate.preventer.mode, .lidClosed)
        XCTAssertTrue(helper.sleepDisabled)
        let expiresAt = try XCTUnwrap(delegate.preventer.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 60 * 60, accuracy: 2)
    }

    func testAllowSleepItemEndsLidClosedMode() throws {
        delegate.preventer.activate(.lidClosed)
        try perform(item("Sleep Normally", in: delegate.buildMenu()))
        XCTAssertEqual(delegate.preventer.mode, .off)
        XCTAssertFalse(helper.sleepDisabled)
    }

    func testAllowSleepItemDeactivates() throws {
        delegate.preventer.activate(for: 60)
        try perform(item("Sleep Normally", in: delegate.buildMenu()))
        XCTAssertFalse(delegate.preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    // MARK: - URL scheme

    func testURLActivateForDuration() throws {
        delegate.handle(URL(string: "redeye://activate?minutes=30")!)
        XCTAssertTrue(delegate.preventer.isActive)
        let expiresAt = try XCTUnwrap(delegate.preventer.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 30 * 60, accuracy: 2)
        XCTAssertEqual(redeyeAssertionCount(), 1)
    }

    func testURLActivateIndefinitelyAndDeactivate() {
        delegate.application(NSApp, open: [URL(string: "redeye://activate")!])
        XCTAssertTrue(delegate.preventer.isActive)
        XCTAssertNil(delegate.preventer.expiresAt)

        delegate.application(NSApp, open: [URL(string: "redeye://deactivate")!])
        XCTAssertFalse(delegate.preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testURLActivateUsesDefaultDurations() throws {
        delegate.handle(URL(string: "redeye://activate?lid=1")!)
        XCTAssertEqual(delegate.preventer.mode, .lidClosed)
        let expiresAt = try XCTUnwrap(delegate.preventer.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 24 * 60 * 60, accuracy: 2)

        delegate.preventer.setDefaultDuration(60 * 60, for: .awake)
        delegate.handle(URL(string: "redeye://activate")!)
        XCTAssertEqual(delegate.preventer.mode, .awake)
        XCTAssertEqual(try XCTUnwrap(delegate.preventer.expiresAt).timeIntervalSinceNow, 60 * 60, accuracy: 2)
    }

    func testURLForeverOverridesDefault() {
        delegate.handle(URL(string: "redeye://activate?lid=1&forever=1")!)
        XCTAssertEqual(delegate.preventer.mode, .lidClosed)
        XCTAssertNil(delegate.preventer.expiresAt)

        delegate.preventer.setDefaultDuration(60 * 60, for: .awake)
        delegate.handle(URL(string: "redeye://activate?forever=1")!)
        XCTAssertEqual(delegate.preventer.mode, .awake)
        XCTAssertNil(delegate.preventer.expiresAt)
    }

    func testLidClosedForeverMenuItemOverridesDefault() throws {
        let submenu = try XCTUnwrap(item("Stay Awake (Ignore Lid)", in: delegate.buildMenu()).submenu)
        try perform(item("Forever", in: submenu))
        XCTAssertEqual(delegate.preventer.mode, .lidClosed)
        XCTAssertNil(delegate.preventer.expiresAt)
    }

    func testURLActivateLidClosed() {
        delegate.handle(URL(string: "redeye://activate?lid=1&hours=2")!)
        XCTAssertEqual(delegate.preventer.mode, .lidClosed)
        XCTAssertTrue(helper.sleepDisabled)
        XCTAssertNotNil(delegate.preventer.expiresAt)

        delegate.handle(URL(string: "redeye://deactivate")!)
        XCTAssertFalse(helper.sleepDisabled)
    }

    func testURLToggle() {
        delegate.handle(URL(string: "redeye://toggle")!)
        XCTAssertTrue(delegate.preventer.isActive)
        delegate.handle(URL(string: "redeye://toggle")!)
        XCTAssertFalse(delegate.preventer.isActive)
    }

    func testUnrecognizedURLChangesNothing() {
        delegate.preventer.activate()
        delegate.handle(URL(string: "redeye://activate?minutes=never")!)
        XCTAssertTrue(delegate.preventer.isActive)
        XCTAssertNil(delegate.preventer.expiresAt)
    }

    // MARK: - Status text

    func testStatusTextWhenSleepAllowed() {
        XCTAssertEqual(delegate.statusText(), "Sleeping Normally")
    }

    func testStatusTextWhenIndefinite() {
        delegate.preventer.activate()
        XCTAssertEqual(delegate.statusText(), "Staying Awake Forever")
    }

    func testStatusTextWhenLidClosed() throws {
        delegate.preventer.activate(.lidClosed, for: nil)
        XCTAssertEqual(delegate.statusText(), "Staying Awake (Ignoring Lid) Forever")
        delegate.preventer.activate(.lidClosed, for: 60 * 60)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let expiresAt = try XCTUnwrap(delegate.preventer.expiresAt)
        XCTAssertEqual(delegate.statusText(), "Staying Awake (Ignoring Lid) Until \(formatter.string(from: expiresAt))")
    }

    func testStatusTextWhenTimed() throws {
        delegate.preventer.activate(for: 60 * 60)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let expiresAt = try XCTUnwrap(delegate.preventer.expiresAt)
        XCTAssertEqual(delegate.statusText(), "Staying Awake Until \(formatter.string(from: expiresAt))")
    }

    // MARK: - Status item

    func testLaunchCreatesStatusItem() throws {
        let button = try XCTUnwrap(launchedDelegate().statusItem.button)
        XCTAssertTrue(button.target === delegate)
        XCTAssertNotNil(button.action)
        XCTAssertNil(delegate.statusItem.menu, "left click should cycle modes, not open a menu")
    }

    func testIconFollowsState() throws {
        let button = try XCTUnwrap(launchedDelegate().statusItem.button)
        let image = try XCTUnwrap(button.image)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(button.toolTip, "Redeye: Sleep Normally")

        delegate.preventer.cycle()
        XCTAssertEqual(button.toolTip, "Redeye: Stay Awake")
        let awake = try XCTUnwrap(button.image)
        XCTAssertFalse(awake.isTemplate, "the awake sun is yellow")
        XCTAssertNotEqual(awake.tiffRepresentation, image.tiffRepresentation, "active icon should differ")

        delegate.preventer.cycle()
        XCTAssertEqual(button.toolTip, "Redeye: Stay Awake (Ignore Lid)")
        let lidClosed = try XCTUnwrap(button.image)
        XCTAssertFalse(lidClosed.isTemplate, "the lid-closed sun is red")
        XCTAssertNotEqual(lidClosed.tiffRepresentation, awake.tiffRepresentation, "red should differ from yellow")

        delegate.preventer.cycle()
        XCTAssertEqual(button.toolTip, "Redeye: Sleep Normally")
        XCTAssertTrue(try XCTUnwrap(button.image).isTemplate)
    }

    func testIconResetsWhenTimerExpires() throws {
        let button = try XCTUnwrap(launchedDelegate().statusItem.button)
        delegate.preventer.activate(for: 0.2)
        XCTAssertEqual(button.toolTip, "Redeye: Stay Awake")
        runMainLoop(for: 0.6)
        XCTAssertEqual(button.toolTip, "Redeye: Sleep Normally")
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

    func testQuittingInLidClosedModeRestoresSleep() {
        delegate.preventer.activate(.lidClosed)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(delegate.preventer.isActive)
        XCTAssertFalse(helper.sleepDisabled)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testQuittingWhileLidClosedRequestIsPendingRestoresSleep() {
        helper.holdReplies = true
        delegate.preventer.activate(.lidClosed)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        helper.reply()
        XCTAssertEqual(helper.requests, [true, false], "the in-flight request is undone")
        XCTAssertFalse(helper.sleepDisabled)
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
