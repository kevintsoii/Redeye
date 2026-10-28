import XCTest
@testable import Redeye

@MainActor
final class URLCommandTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(command("redeye://activate"), .activate())
        XCTAssertEqual(command("redeye://deactivate"), .deactivate)
        XCTAssertEqual(command("redeye://toggle"), .toggle)
    }

    func testKeepingYouAwakeStyleAndCase() {
        XCTAssertEqual(command("redeye:///activate"), .activate())
        XCTAssertEqual(command("redeye:///toggle/"), .toggle)
        XCTAssertEqual(command("REDEYE://Deactivate"), .deactivate)
    }

    func testDurations() {
        XCTAssertEqual(command("redeye://activate?seconds=90"), .activate(.timed(90)))
        XCTAssertEqual(command("redeye://activate?minutes=30"), .activate(.timed(30 * 60)))
        XCTAssertEqual(command("redeye://activate?hours=1.5"), .activate(.timed(90 * 60)))
        XCTAssertEqual(command("redeye://activate?hours=1&minutes=30&seconds=5"), .activate(.timed(90 * 60 + 5)))
        XCTAssertEqual(command("redeye://activate?other=1"), .activate(), "unknown parameters are ignored")
    }

    func testLidClosed() {
        XCTAssertEqual(command("redeye://activate?lid=1"), .activate(lidClosed: true))
        XCTAssertEqual(command("redeye://activate?lid=true&hours=2"), .activate(.timed(2 * 60 * 60), lidClosed: true))
        XCTAssertEqual(command("redeye://activate?LID=yes"), .activate(lidClosed: true))
        XCTAssertEqual(command("redeye://activate?lid=0"), .activate())
        XCTAssertNil(command("redeye://activate?lid=maybe"))
        XCTAssertNil(command("redeye://activate?lid"))
    }

    func testForever() {
        XCTAssertEqual(command("redeye://activate?forever=1"), .activate(.forever))
        XCTAssertEqual(command("redeye://activate?lid=1&forever=true"), .activate(.forever, lidClosed: true))
        XCTAssertEqual(command("redeye://activate?FOREVER=yes"), .activate(.forever))
        XCTAssertEqual(command("redeye://activate?forever=0"), .activate(), "forever=0 means the mode's default")
        XCTAssertEqual(command("redeye://activate?forever=0&hours=2"), .activate(.timed(2 * 60 * 60)))
        XCTAssertNil(command("redeye://activate?forever=1&hours=2"), "forever and a time contradict each other")
        XCTAssertNil(command("redeye://activate?forever=sometimes"))
        XCTAssertNil(command("redeye://activate?forever"))
    }

    func testInvalidURLs() {
        XCTAssertNil(command("redeye://sleep"))
        XCTAssertNil(command("redeye://"))
        XCTAssertNil(command("https://activate"))
        XCTAssertNil(command("redeye://activate?minutes=0"))
        XCTAssertNil(command("redeye://activate?minutes=-5"))
        XCTAssertNil(command("redeye://activate?minutes=soon"))
        XCTAssertNil(command("redeye://activate?hours="))
    }

    func testAppRegistersScheme() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [URLCommand.scheme])
    }

    private func command(_ string: String) -> URLCommand? {
        URLCommand(url: URL(string: string)!)
    }
}
