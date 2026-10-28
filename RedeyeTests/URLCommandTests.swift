import XCTest
@testable import Redeye

@MainActor
final class URLCommandTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(command("redeye://activate"), .activate(nil))
        XCTAssertEqual(command("redeye://deactivate"), .deactivate)
        XCTAssertEqual(command("redeye://toggle"), .toggle)
    }

    func testKeepingYouAwakeStyleAndCase() {
        XCTAssertEqual(command("redeye:///activate"), .activate(nil))
        XCTAssertEqual(command("redeye:///toggle/"), .toggle)
        XCTAssertEqual(command("REDEYE://Deactivate"), .deactivate)
    }

    func testDurations() {
        XCTAssertEqual(command("redeye://activate?seconds=90"), .activate(90))
        XCTAssertEqual(command("redeye://activate?minutes=30"), .activate(30 * 60))
        XCTAssertEqual(command("redeye://activate?hours=1.5"), .activate(90 * 60))
        XCTAssertEqual(command("redeye://activate?hours=1&minutes=30&seconds=5"), .activate(90 * 60 + 5))
        XCTAssertEqual(command("redeye://activate?other=1"), .activate(nil), "unknown parameters are ignored")
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
