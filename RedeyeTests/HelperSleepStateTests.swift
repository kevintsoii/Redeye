import XCTest

/// The privileged helper's bookkeeping, with `pmset` faked. `HelperSleepState.swift` is compiled
/// into this test target directly, since it isn't part of the app.
@MainActor
final class HelperSleepStateTests: XCTestCase {
    /// Every `pmset -a disablesleep` call: true for 1, false for 0.
    private var pmsetCalls: [Bool] = []
    /// Results to return from the next pmset calls, in order. Empty means succeed.
    private var pmsetResults: [Bool] = []
    private var sleepDisabled = false

    private lazy var state = HelperSleepState { [unowned self] disabled in
        pmsetCalls.append(disabled)
        let ok = pmsetResults.isEmpty ? true : pmsetResults.removeFirst()
        if ok { sleepDisabled = disabled }
        return ok
    }

    private let app = UUID()
    private let other = UUID()

    func testDisableAndRestore() {
        state.connected(app)
        XCTAssertTrue(state.set(true, for: app))
        XCTAssertTrue(sleepDisabled)
        XCTAssertTrue(state.set(false, for: app))
        XCTAssertFalse(sleepDisabled)
        XCTAssertEqual(pmsetCalls, [true, false])
    }

    func testRepeatedRequestsDontRerunPmset() {
        state.connected(app)
        _ = state.set(true, for: app)
        _ = state.set(true, for: app)
        _ = state.set(false, for: app)
        _ = state.set(false, for: app)
        XCTAssertEqual(pmsetCalls, [true, false])
    }

    func testAllowingSleepWhenNothingDisabledItDoesNothing() {
        state.connected(app)
        XCTAssertTrue(state.set(false, for: app))
        XCTAssertEqual(pmsetCalls, [])
    }

    // MARK: - App goes away

    func testDisconnectRestoresSleep() {
        // What happens when Redeye quits, crashes or is force-killed: XPC invalidates the connection.
        state.connected(app)
        _ = state.set(true, for: app)
        state.disconnected(app)
        XCTAssertFalse(sleepDisabled)
        XCTAssertFalse(state.isSleepDisabled)
        XCTAssertTrue(state.isIdle)
    }

    func testDisconnectWithoutDisablingDoesNothing() {
        state.connected(app)
        state.disconnected(app)
        XCTAssertEqual(pmsetCalls, [])
        XCTAssertTrue(state.isIdle)
    }

    func testSleepStaysDisabledUntilLastHolderLetsGo() {
        state.connected(app)
        state.connected(other)
        _ = state.set(true, for: app)
        _ = state.set(true, for: other)
        state.disconnected(app)
        XCTAssertTrue(sleepDisabled, "another connection still wants it")
        XCTAssertFalse(state.isIdle)
        state.disconnected(other)
        XCTAssertFalse(sleepDisabled)
        XCTAssertEqual(pmsetCalls, [true, false])
    }

    func testIdleTracksConnections() {
        XCTAssertTrue(state.isIdle)
        state.connected(app)
        XCTAssertFalse(state.isIdle)
        state.disconnected(app)
        XCTAssertTrue(state.isIdle)
    }

    // MARK: - pmset failures

    func testFailedDisableIsNotRecorded() {
        state.connected(app)
        pmsetResults = [false]
        XCTAssertFalse(state.set(true, for: app))
        XCTAssertFalse(state.isSleepDisabled)

        // The next request must actually run pmset, not assume it's already on.
        XCTAssertTrue(state.set(true, for: app))
        XCTAssertTrue(sleepDisabled)
        XCTAssertEqual(pmsetCalls, [true, true])
    }

    func testRestoreRetries() {
        state.connected(app)
        _ = state.set(true, for: app)
        pmsetResults = [false, false, true]
        XCTAssertTrue(state.set(false, for: app))
        XCTAssertFalse(sleepDisabled)
        XCTAssertEqual(pmsetCalls, [true, false, false, false])
    }

    func testRestoreGivesUpAfterThreeTries() {
        pmsetResults = [false, false, false, false]
        XCTAssertFalse(state.restoreSleep())
        XCTAssertEqual(pmsetCalls, [false, false, false])
    }

    // MARK: - Helper start, idle exit, SIGTERM

    func testRestoreSleepAlwaysRunsPmset() {
        // On start, before idle exit and on SIGTERM the helper resets even if it thinks nothing is
        // disabled: a previous helper (before a reboot or crash) may have left it on.
        XCTAssertTrue(state.restoreSleep())
        XCTAssertEqual(pmsetCalls, [false])
    }

    func testRestoreSleepClearsHolders() {
        state.connected(app)
        _ = state.set(true, for: app)
        state.restoreSleep()
        XCTAssertFalse(state.isSleepDisabled)
        XCTAssertFalse(sleepDisabled)
        // A later disable request runs pmset again.
        _ = state.set(true, for: app)
        XCTAssertEqual(pmsetCalls, [true, false, true])
    }
}
