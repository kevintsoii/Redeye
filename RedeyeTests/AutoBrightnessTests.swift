import CoreGraphics
import XCTest
@testable import Redeye

@MainActor
final class AutoBrightnessTests: XCTestCase {
    private var calls: [(CGDirectDisplayID, Bool)] = []

    private func makeBrightness(displays: [CGDirectDisplayID]) -> AutoBrightness {
        AutoBrightness(displays: { displays }, setEnabled: { [unowned self] in calls.append(($0, $1)) }, pause: 0.05)
    }

    func testResetTurnsOffThenOnForEachDisplay() {
        let brightness = makeBrightness(displays: [1, 2])
        brightness.reset()
        XCTAssertEqual(calls.map(\.0), [1, 2])
        XCTAssertEqual(calls.map(\.1), [false, false])  // back on only after the pause

        runMainLoop(for: 0.2)
        XCTAssertEqual(calls.map(\.0), [1, 2, 1, 2])
        XCTAssertEqual(calls.map(\.1), [false, false, true, true])
    }

    func testNoSensorMeansUnavailableAndNoCalls() {
        let brightness = makeBrightness(displays: [])
        XCTAssertFalse(brightness.isAvailable)
        brightness.reset()
        runMainLoop(for: 0.2)
        XCTAssertTrue(calls.isEmpty)
    }

    func testAvailableWithSensor() {
        XCTAssertTrue(makeBrightness(displays: [1]).isAvailable)
    }
}
