import ServiceManagement
import XCTest
@testable import Redeye

@MainActor
final class LidSleepHelperTests: XCTestCase {
    private lazy var service = FakeHelperService()
    private lazy var connection = FakeHelperConnection()
    private lazy var defaults = makeTestDefaults(for: self)
    private lazy var helper = LidSleepHelper(
        service: service,
        connection: connection,
        defaults: defaults,
        helperHash: { "current" },
        replyTimeout: 0.05,
        registerRetryDelay: 0.01
    )

    private var registeredHash: String? {
        defaults.string(forKey: LidSleepHelper.registeredHashKey)
    }

    /// Asks the helper to disable sleep and waits for the answer. Returns nil while there's none.
    private func disableSleep() -> Result<Void, Error>? {
        var result: Result<Void, Error>?
        helper.setSleepDisabled(true) { error in
            result = error.map { .failure($0) } ?? .success(())
        }
        runMainLoop(until: { result != nil })
        return result
    }

    func testRegisteredHelperIsUsedAsIs() throws {
        defaults.set("current", forKey: LidSleepHelper.registeredHashKey)
        try XCTUnwrap(disableSleep()).get()
        XCTAssertEqual(service.calls, [])
        XCTAssertEqual(connection.sent, [true])
    }

    func testChangedHelperIsRegisteredAgainFirst() throws {
        defaults.set("old", forKey: LidSleepHelper.registeredHashKey)
        try XCTUnwrap(disableSleep()).get()
        XCTAssertEqual(service.calls, ["unregister", "register"])
        XCTAssertEqual(registeredHash, "current")
        XCTAssertEqual(connection.sent, [true])
    }

    /// launchd can still hold an older helper build even though Redeye thinks it registered this one.
    /// It then never starts the helper, and the request gets no answer at all.
    func testHelperThatDoesNotStartIsRegisteredAgainAndRetried() throws {
        defaults.set("current", forKey: LidSleepHelper.registeredHashKey)
        connection.answers = [.silent]
        try XCTUnwrap(disableSleep()).get()
        XCTAssertEqual(service.calls, ["unregister", "register"])
        XCTAssertEqual(connection.sent, [true, true])
        XCTAssertEqual(connection.resets, 1, "the unanswered request is dropped")
        XCTAssertEqual(registeredHash, "current")
    }

    func testHelperThatNeverStartsFailsAfterOneRetry() throws {
        defaults.set("current", forKey: LidSleepHelper.registeredHashKey)
        connection.answers = [.silent, .silent]
        let result = try XCTUnwrap(disableSleep())
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(service.calls, ["unregister", "register"])
        XCTAssertEqual(connection.sent, [true, true])
        XCTAssertEqual(connection.resets, 2)
    }

    /// Right after unregistering, `register()` fails until Background Task Management catches up.
    func testRegisteringAgainWaitsForUnregisterToSettle() throws {
        defaults.set("old", forKey: LidSleepHelper.registeredHashKey)
        service.failingRegisters = 3
        try XCTUnwrap(disableSleep()).get()
        XCTAssertEqual(service.calls, ["unregister", "register", "register", "register", "register"])
        XCTAssertEqual(registeredHash, "current")
        XCTAssertEqual(connection.sent, [true])
    }

    func testFailedRegistrationIsNotRememberedAndIsTriedAgain() throws {
        defaults.set("old", forKey: LidSleepHelper.registeredHashKey)
        service.failingRegisters = 100
        XCTAssertThrowsError(try XCTUnwrap(disableSleep()).get())
        XCTAssertNil(registeredHash)
        XCTAssertEqual(connection.sent, [])
        XCTAssertEqual(service.calls.count, 12, "unregister, then register 11 times")

        service.status = .enabled
        service.failingRegisters = 0
        try XCTUnwrap(disableSleep()).get()
        XCTAssertEqual(service.calls.suffix(2), ["unregister", "register"])
        XCTAssertEqual(registeredHash, "current")
    }

    func testFirstRegistrationNeedingApprovalIsReported() throws {
        service.status = .notRegistered
        service.statusAfterRegister = .requiresApproval
        let result = try XCTUnwrap(disableSleep())
        XCTAssertThrowsError(try result.get()) { error in
            guard case LidSleepError.needsApproval = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(registeredHash)
        XCTAssertEqual(connection.sent, [])
    }

    func testFirstRegistrationIsRemembered() throws {
        service.status = .notRegistered
        try XCTUnwrap(disableSleep()).get()
        XCTAssertEqual(service.calls, ["register"])
        XCTAssertEqual(registeredHash, "current")
    }

    /// Switching modes while waiting must never let the retry disable sleep afterwards.
    func testAllowingSleepWhileWaitingStopsTheRetry() {
        defaults.set("current", forKey: LidSleepHelper.registeredHashKey)
        connection.answers = [.silent]
        var answered = false
        helper.setSleepDisabled(true) { _ in answered = true }
        helper.setSleepDisabled(false) { _ in }
        runMainLoop(for: 0.3)
        XCTAssertFalse(answered)
        XCTAssertEqual(service.calls, [])
        XCTAssertEqual(connection.sent, [true, false])
    }

    func testDropWhileWaitingIsRetriedInsteadOfReported() throws {
        defaults.set("current", forKey: LidSleepHelper.registeredHashKey)
        connection.answers = [.silent]
        var lost = 0
        helper.onConnectionLost = { lost += 1 }
        var result: Error??
        helper.setSleepDisabled(true) { result = .some($0) }
        connection.drop()
        runMainLoop(until: { result != nil })
        XCTAssertNil(try XCTUnwrap(result))
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(connection.sent, [true, true])
    }

    func testDropAfterSleepIsDisabledIsReported() throws {
        defaults.set("current", forKey: LidSleepHelper.registeredHashKey)
        var lost = 0
        helper.onConnectionLost = { lost += 1 }
        try XCTUnwrap(disableSleep()).get()
        connection.drop()
        XCTAssertEqual(lost, 1)
    }

    func testAllowingSleepWithoutAConnectionSendsNothing() {
        var answered = false
        helper.setSleepDisabled(false) { error in
            XCTAssertNil(error)
            answered = true
        }
        XCTAssertTrue(answered)
        XCTAssertEqual(connection.sent, [])
    }

    func testRefreshRegistersAgainOnlyWhenTheHelperChanged() {
        defaults.set("current", forKey: LidSleepHelper.registeredHashKey)
        helper.refreshRegistration()
        runMainLoop(for: 0.1)
        XCTAssertEqual(service.calls, [])

        defaults.set("old", forKey: LidSleepHelper.registeredHashKey)
        helper.refreshRegistration()
        runMainLoop(until: { registeredHash == "current" })
        XCTAssertEqual(service.calls, ["unregister", "register"])
    }
}
