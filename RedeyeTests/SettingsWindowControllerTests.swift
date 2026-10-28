import AppKit
import ServiceManagement
import XCTest
@testable import Redeye

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testWindowStyle() throws {
        let window = try XCTUnwrap(SettingsWindowController().window)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.isReleasedWhenClosed, "the controller reopens the same window")
    }

    func testTabs() throws {
        let tabs = try XCTUnwrap(SettingsWindowController().window?.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "About"])
        XCTAssertEqual(tabs.tabViewItems.map { $0.viewController?.title }, ["General", "About"])
        XCTAssertTrue(tabs.tabViewItems[0].viewController is GeneralSettingsViewController)
        XCTAssertTrue(tabs.tabViewItems[1].viewController is AboutViewController)
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

    func testGeneralHasSize() {
        let general = GeneralSettingsViewController()
        general.loadView()
        XCTAssertGreaterThan(general.preferredContentSize.width, 0)
        XCTAssertGreaterThan(general.preferredContentSize.height, 0)
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
}
