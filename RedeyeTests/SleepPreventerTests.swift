import IOKit.pwr_mgt
import XCTest
@testable import Redeye

@MainActor
final class SleepPreventerTests: XCTestCase {
    /// A fresh preventer per test, released afterwards so assertions don't leak between tests.
    private lazy var preventer = makePreventer()

    private func makePreventer() -> SleepPreventer {
        let preventer = SleepPreventer()
        addTeardownBlock { @MainActor in preventer.deactivate(notify: false) }
        return preventer
    }

    func testStartsInactive() {
        XCTAssertFalse(preventer.isActive)
        XCTAssertNil(preventer.expiresAt)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testActivateIndefinitely() {
        preventer.activate()
        XCTAssertTrue(preventer.isActive)
        XCTAssertNil(preventer.expiresAt)
        XCTAssertTrue(hasRedeyeAssertion())
    }

    func testAssertionLetsDisplaySleep() {
        preventer.activate()
        let types = redeyeAssertions().map { $0[kIOPMAssertionTypeKey] as? String }
        XCTAssertEqual(types, [kIOPMAssertionTypePreventUserIdleSystemSleep])
    }

    func testDeactivateReleasesAssertion() {
        preventer.activate()
        preventer.deactivate()
        XCTAssertFalse(preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testDeactivateWhenInactiveIsSafe() {
        preventer.deactivate()
        preventer.deactivate(notify: false)
        XCTAssertFalse(preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testActivateWithDurationSetsExpiry() throws {
        let before = Date()
        preventer.activate(for: 60 * 60)
        XCTAssertTrue(preventer.isActive)
        let expiresAt = try XCTUnwrap(preventer.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince(before), 60 * 60, accuracy: 1)
    }

    func testReactivatingReplacesPreviousAssertion() {
        preventer.activate(for: 60)
        preventer.activate()
        XCTAssertNil(preventer.expiresAt)
        XCTAssertEqual(redeyeAssertionCount(), 1)
    }

    func testIndefiniteAfterTimedCancelsOldTimer() {
        preventer.activate(for: 0.2)
        preventer.activate()
        runMainLoop(for: 0.5)
        XCTAssertTrue(preventer.isActive)
        XCTAssertTrue(hasRedeyeAssertion())
    }

    func testNewDurationReplacesOldTimer() throws {
        preventer.activate(for: 0.2)
        preventer.activate(for: 60)
        runMainLoop(for: 0.5)
        XCTAssertTrue(preventer.isActive)
        let expiresAt = try XCTUnwrap(preventer.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 60, accuracy: 2)
    }

    func testExpiryDeactivates() {
        let expired = expectation(description: "expired")
        preventer.activate(for: 0.2)
        preventer.onChange = { [unowned self] in
            if !preventer.isActive { expired.fulfill() }
        }
        wait(for: [expired], timeout: 2)
        XCTAssertNil(preventer.expiresAt)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testIndefiniteDoesNotExpire() {
        preventer.activate()
        runMainLoop(for: 0.5)
        XCTAssertTrue(preventer.isActive)
    }

    func testDeactivateCancelsExpiryTimer() {
        var changes = 0
        preventer.activate(for: 0.2)
        preventer.deactivate()
        preventer.onChange = { changes += 1 }
        runMainLoop(for: 0.5)
        XCTAssertEqual(changes, 0)
    }

    func testToggle() {
        preventer.toggle()
        XCTAssertTrue(preventer.isActive)
        XCTAssertNil(preventer.expiresAt, "toggling on is indefinite")
        preventer.toggle()
        XCTAssertFalse(preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testToggleEndsTimedSession() {
        preventer.activate(for: 60)
        preventer.toggle()
        XCTAssertFalse(preventer.isActive)
        XCTAssertNil(preventer.expiresAt)
    }

    func testOnChangeNotifications() {
        var changes = 0
        preventer.onChange = { changes += 1 }
        preventer.activate()
        XCTAssertEqual(changes, 1)
        preventer.activate(for: 60)  // the internal deactivate shouldn't notify
        XCTAssertEqual(changes, 2)
        preventer.deactivate(notify: false)
        XCTAssertEqual(changes, 2)
        preventer.deactivate()
        XCTAssertEqual(changes, 3)
    }

    func testOnChangeSeesNewState() {
        var seen: [Bool] = []
        preventer.onChange = { [unowned self] in seen.append(preventer.isActive) }
        preventer.toggle()
        preventer.toggle()
        XCTAssertEqual(seen, [true, false])
    }

    func testPreventersAreIndependent() {
        let other = makePreventer()
        preventer.activate()
        other.activate(for: 60)
        XCTAssertEqual(redeyeAssertionCount(), 2)
        other.deactivate()
        XCTAssertTrue(preventer.isActive)
        XCTAssertEqual(redeyeAssertionCount(), 1)
    }
}
