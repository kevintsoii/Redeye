import AppKit
import XCTest
@testable import Redeye

@MainActor
final class SingleInstanceTests: XCTestCase {
    func testFindsOtherRunningApps() {
        // Finder is always running and isn't this process.
        XCTAssertFalse(SingleInstance.otherInstances(of: "com.apple.finder").isEmpty)
    }

    func testExcludesThisProcess() throws {
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let others = SingleInstance.otherInstances(of: bundleID)
        XCTAssertFalse(others.contains { $0.processIdentifier == getpid() })
    }

    func testNoInstancesForUnknownBundleID() {
        XCTAssertTrue(SingleInstance.otherInstances(of: "com.example.not-installed").isEmpty)
        XCTAssertTrue(SingleInstance.otherInstances(of: nil).isEmpty)
    }

    func testNeverQuitsUnderTests() {
        XCTAssertFalse(SingleInstance.shouldQuit(environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
    }
}
