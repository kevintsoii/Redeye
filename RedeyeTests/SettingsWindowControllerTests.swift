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
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Stay Awake", "Safety", "About"])
        XCTAssertEqual(tabs.tabViewItems.map { $0.viewController?.title }, ["General", "Stay Awake", "Safety", "About"])
        XCTAssertTrue(tabs.tabViewItems[0].viewController is GeneralSettingsViewController)
        XCTAssertTrue(tabs.tabViewItems[1].viewController is StayAwakeSettingsViewController)
        XCTAssertTrue(tabs.tabViewItems[2].viewController is SafetySettingsViewController)
        XCTAssertTrue(tabs.tabViewItems[3].viewController is AboutViewController)
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
        let tabs = [
            GeneralSettingsViewController(),
            StayAwakeSettingsViewController(preventer: makePreventer()),
            SafetySettingsViewController(preventer: makePreventer()),
        ]
        for tab in tabs {
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

    func testDefaultDurationPopUps() throws {
        let preventer = makePreventer()
        let stayAwake = StayAwakeSettingsViewController(preventer: preventer)
        stayAwake.loadView()
        stayAwake.viewWillAppear()

        let popUps = descendants(of: stayAwake.view, ofType: NSPopUpButton.self)
        XCTAssertEqual(popUps.count, 2)
        for popUp in popUps {
            XCTAssertEqual(popUp.itemTitles, ["Forever", "30 Minutes", "1 Hour", "6 Hours", "12 Hours", "24 Hours"])
        }
        let awake = popUps[0], lidClosed = popUps[1]
        XCTAssertEqual(awake.titleOfSelectedItem, "Forever")
        XCTAssertEqual(lidClosed.titleOfSelectedItem, "24 Hours")

        awake.selectItem(withTitle: "6 Hours")
        try perform(awake)
        lidClosed.selectItem(withTitle: "Forever")
        try perform(lidClosed)
        XCTAssertEqual(preventer.defaultDuration(for: .awake), 6 * 60 * 60)
        XCTAssertNil(preventer.defaultDuration(for: .lidClosed))
    }

    func testDefaultDurationPopUpsReflectSavedSettings() {
        let preventer = makePreventer()
        preventer.setDefaultDuration(30 * 60, for: .awake)
        preventer.setDefaultDuration(nil, for: .lidClosed)
        let stayAwake = StayAwakeSettingsViewController(preventer: preventer)
        stayAwake.loadView()
        stayAwake.viewWillAppear()
        let popUps = descendants(of: stayAwake.view, ofType: NSPopUpButton.self)
        XCTAssertEqual(popUps.map(\.titleOfSelectedItem), ["30 Minutes", "Forever"])
    }

    // MARK: - Safety

    func testSafetyControlsAreOffByDefault() throws {
        let safety = SafetySettingsViewController(preventer: makePreventer())
        safety.loadView()
        safety.viewWillAppear()

        let battery = try checkbox("Let the Mac sleep when the battery is below", in: safety.view)
        let heat = try checkbox("Let the Mac sleep when it gets too hot", in: safety.view)
        let percent = try XCTUnwrap(descendants(of: safety.view, ofType: NSPopUpButton.self).first)
        XCTAssertEqual(battery.state, .off)
        XCTAssertEqual(heat.state, .off)
        XCTAssertEqual(percent.itemTitles, ["10%", "20%", "30%", "40%", "50%"])
        XCTAssertEqual(percent.titleOfSelectedItem, "20%")
        XCTAssertFalse(percent.isEnabled, "the percentage only matters with the cutoff on")
    }

    func testSafetyControlsChangeSettings() throws {
        let preventer = makePreventer()
        let safety = SafetySettingsViewController(preventer: preventer)
        safety.loadView()
        safety.viewWillAppear()

        let battery = try checkbox("Let the Mac sleep when the battery is below", in: safety.view)
        let heat = try checkbox("Let the Mac sleep when it gets too hot", in: safety.view)
        let percent = try XCTUnwrap(descendants(of: safety.view, ofType: NSPopUpButton.self).first)

        battery.state = .on
        try perform(battery)
        XCTAssertTrue(preventer.batteryCutoff)
        XCTAssertTrue(percent.isEnabled)
        percent.selectItem(withTitle: "40%")
        try perform(percent)
        XCTAssertEqual(preventer.batteryCutoffPercent, 40)
        heat.state = .on
        try perform(heat)
        XCTAssertTrue(preventer.heatCutoff)

        let reopened = SafetySettingsViewController(preventer: preventer)
        reopened.loadView()
        reopened.viewWillAppear()
        XCTAssertEqual(try checkbox("Let the Mac sleep when the battery is below", in: reopened.view).state, .on)
        XCTAssertEqual(try checkbox("Let the Mac sleep when it gets too hot", in: reopened.view).state, .on)
        XCTAssertEqual(descendants(of: reopened.view, ofType: NSPopUpButton.self).first?.titleOfSelectedItem, "40%")
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
        SleepPreventer(defaults: makeTestDefaults(for: self), sleepDisabler: FakeSleepDisabler(), powerMonitor: FakePowerMonitor())
    }

    private func checkbox(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: view, ofType: NSButton.self).first { $0.title == title }, "no checkbox \"\(title)\"")
    }

    /// Sends the control's action to its target, like clicking it.
    private func perform(_ control: NSControl) throws {
        let action = try XCTUnwrap(control.action)
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control))
    }
}
