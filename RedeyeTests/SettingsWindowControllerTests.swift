import AppKit
import ServiceManagement
import XCTest
@testable import Redeye

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testWindowStyle() throws {
        let window = try XCTUnwrap(SettingsWindowController(preventer: makePreventer()).window)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.isReleasedWhenClosed, "the controller reopens the same window")
    }

    func testTabs() throws {
        let tabs = try XCTUnwrap(SettingsWindowController(preventer: makePreventer()).window?.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Stay Awake", "About"])
        XCTAssertEqual(tabs.tabViewItems.map { $0.viewController?.title }, ["General", "Stay Awake", "About"])
        XCTAssertTrue(tabs.tabViewItems[0].viewController is GeneralSettingsViewController)
        XCTAssertTrue(tabs.tabViewItems[1].viewController is StayAwakeSettingsViewController)
        XCTAssertTrue(tabs.tabViewItems[2].viewController is AboutViewController)
        for tab in tabs.tabViewItems {
            XCTAssertNotNil(tab.image, "\(tab.label) tab has no icon")
        }
    }

    // MARK: - General

    func testLaunchAtLoginCheckboxReflectsSystemSetting() throws {
        let general = GeneralSettingsViewController()
        general.loadView()
        general.viewWillAppear()

        let checkbox = try XCTUnwrap(descendants(of: general.view, ofType: NSButton.self).first)
        XCTAssertEqual(checkbox.title, "Launch at login")
        XCTAssertTrue(checkbox.target === general)
        XCTAssertNotNil(checkbox.action)
        XCTAssertEqual(checkbox.state, SMAppService.mainApp.status == .enabled ? .on : .off)
    }

    func testGeneralHasOnlyLaunchAtLogin() {
        let general = GeneralSettingsViewController()
        general.loadView()
        XCTAssertEqual(descendants(of: general.view, ofType: NSButton.self).map(\.title), ["Launch at login"])
    }

    // MARK: - Stay Awake

    func testKeepDisplayOnCheckbox() throws {
        let preventer = makePreventer()
        let stayAwake = StayAwakeSettingsViewController(preventer: preventer)
        stayAwake.loadView()
        stayAwake.viewWillAppear()

        let checkbox = try XCTUnwrap(descendants(of: stayAwake.view, ofType: NSButton.self)
            .first { $0.title == "Keep screen on while staying awake" })
        XCTAssertEqual(checkbox.state, .off, "off by default, like caffeinate -i")

        checkbox.state = .on
        let action = try XCTUnwrap(checkbox.action)
        XCTAssertTrue(NSApp.sendAction(action, to: checkbox.target, from: checkbox))
        XCTAssertTrue(preventer.keepDisplayOn)
    }

    func testTabsHaveSize() {
        for tab in [GeneralSettingsViewController(), StayAwakeSettingsViewController(preventer: makePreventer())] {
            tab.loadView()
            XCTAssertGreaterThan(tab.preferredContentSize.width, 0)
            XCTAssertGreaterThan(tab.preferredContentSize.height, 0)
        }
    }

    func testCheckboxReflectsSavedSetting() throws {
        let preventer = makePreventer()
        preventer.keepDisplayOn = true
        let stayAwake = StayAwakeSettingsViewController(preventer: preventer)
        stayAwake.loadView()
        stayAwake.viewWillAppear()
        let checkbox = try XCTUnwrap(descendants(of: stayAwake.view, ofType: NSButton.self).first)
        XCTAssertEqual(checkbox.state, .on)
    }

    // MARK: - About

    func testAboutShowsNameAndVersion() {
        let about = AboutViewController()
        about.loadView()
        let labels = descendants(of: about.view, ofType: NSTextField.self).map(\.stringValue)

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        XCTAssertNotNil(version, "MARKETING_VERSION missing from Info.plist")
        XCTAssertNotNil(build, "CURRENT_PROJECT_VERSION missing from Info.plist")

        XCTAssertTrue(labels.contains("Redeye"))
        XCTAssertTrue(labels.contains("Version \(version ?? "") (\(build ?? ""))"), "\(labels)")
        XCTAssertFalse(labels.contains { $0.contains("?") }, "version fell back to \"?\"")
    }

    func testAboutShowsAppIcon() throws {
        let about = AboutViewController()
        about.loadView()
        let icon = try XCTUnwrap(descendants(of: about.view, ofType: NSImageView.self).first)
        XCTAssertNotNil(icon.image)
    }

    private func makePreventer() -> SleepPreventer {
        SleepPreventer(defaults: makeTestDefaults(for: self), sleepDisabler: FakeSleepDisabler())
    }
}
