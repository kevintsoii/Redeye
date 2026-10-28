import IOKit.pwr_mgt
import XCTest
@testable import Redeye

@MainActor
final class SleepPreventerTests: XCTestCase {
    /// A fresh preventer per test, released afterwards so assertions don't leak between tests.
    private lazy var preventer = makePreventer()
    private lazy var helper = FakeSleepDisabler()
    private lazy var power = FakePowerMonitor()
    private lazy var defaults = makeTestDefaults(for: self)

    private func makePreventer() -> SleepPreventer {
        let preventer = SleepPreventer(defaults: defaults, sleepDisabler: helper, powerMonitor: power)
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
        XCTAssertNil(preventer.expiresAt, "Stay Awake defaults to Forever")
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

    // MARK: - Modes

    func testModeFollowsActivation() {
        XCTAssertEqual(preventer.mode, .off)
        preventer.activate()
        XCTAssertEqual(preventer.mode, .awake)
        preventer.activate(.lidClosed)
        XCTAssertEqual(preventer.mode, .lidClosed)
        preventer.deactivate()
        XCTAssertEqual(preventer.mode, .off)
    }

    func testCycleStepsThroughModes() {
        var seen: [SleepMode] = []
        for _ in 0..<4 {
            preventer.cycle()
            seen.append(preventer.mode)
        }
        XCTAssertEqual(seen, [.awake, .lidClosed, .off, .awake])
    }

    func testCycleUsesEachModesDefaultDuration() throws {
        preventer.cycle()
        XCTAssertNil(preventer.expiresAt, "Stay Awake defaults to Forever")
        preventer.cycle()
        let expiresAt = try XCTUnwrap(preventer.expiresAt, "Stay Awake (Ignore Lid) defaults to 24 hours")
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 24 * 60 * 60, accuracy: 2)
    }

    func testAwakeDoesNotUseHelper() {
        preventer.activate()
        preventer.deactivate()
        XCTAssertEqual(helper.requests, [])
    }

    func testLidClosedDisablesSleepAndHoldsAssertion() {
        preventer.activate(.lidClosed, for: 60)
        XCTAssertEqual(helper.requests, [true])
        XCTAssertEqual(redeyeAssertionCount(), 1)
        XCTAssertNotNil(preventer.expiresAt)
    }

    func testLeavingLidClosedRestoresSleep() {
        preventer.activate(.lidClosed)
        preventer.activate(.awake)
        XCTAssertEqual(helper.requests, [true, false])
        XCTAssertEqual(preventer.mode, .awake)
        XCTAssertTrue(hasRedeyeAssertion())

        preventer.activate(.lidClosed)
        preventer.deactivate()
        XCTAssertEqual(helper.requests, [true, false, true, false])
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testDeactivateWithoutNotifyStillRestoresSleep() {
        preventer.activate(.lidClosed)
        preventer.deactivate(notify: false)  // what quitting does
        XCTAssertFalse(helper.sleepDisabled)
    }

    func testLidClosedExpiryRestoresSleep() {
        preventer.activate(.lidClosed, for: 0.2)
        runMainLoop(for: 0.6)
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertFalse(helper.sleepDisabled)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testHelperFailureFallsBackToOffAndReports() {
        var errors: [Error] = []
        preventer.onError = { errors.append($0) }
        helper.error = LidSleepError.needsApproval
        preventer.activate()
        preventer.cycle()
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertFalse(hasRedeyeAssertion())
        XCTAssertEqual(errors.count, 1)
        XCTAssertFalse(helper.sleepDisabled)
    }

    func testStaysInPreviousModeUntilHelperReplies() {
        helper.holdReplies = true
        preventer.activate()
        preventer.activate(.lidClosed)
        XCTAssertEqual(preventer.mode, .awake)
        helper.reply()
        XCTAssertEqual(preventer.mode, .lidClosed)
    }

    func testLateHelperReplyAfterDeactivateIsIgnored() {
        helper.holdReplies = true
        preventer.activate(.lidClosed)
        preventer.deactivate()
        helper.reply()
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertEqual(helper.requests, [true, false], "the cancelled request is undone")
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testLosingHelperConnectionStopsLidClosedMode() {
        var errors: [Error] = []
        preventer.onError = { errors.append($0) }
        preventer.activate(.lidClosed)
        helper.onConnectionLost?()
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertFalse(hasRedeyeAssertion())
        XCTAssertEqual(errors.count, 1)
    }

    func testLosingHelperConnectionWhileAwakeIsIgnored() {
        var errors: [Error] = []
        preventer.onError = { errors.append($0) }
        preventer.activate()
        helper.onConnectionLost?()
        XCTAssertEqual(preventer.mode, .awake)
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - Keep display on

    func testKeepDisplayOnUsesDisplayAssertion() {
        preventer.keepDisplayOn = true
        preventer.activate()
        let types = redeyeAssertions().map { $0[kIOPMAssertionTypeKey] as? String }
        XCTAssertEqual(types, [kIOPMAssertionTypePreventUserIdleDisplaySleep])
    }

    func testChangingKeepDisplayOnWhileActiveSwapsAssertion() {
        preventer.activate(for: 60)
        preventer.keepDisplayOn = true
        var types = redeyeAssertions().map { $0[kIOPMAssertionTypeKey] as? String }
        XCTAssertEqual(types, [kIOPMAssertionTypePreventUserIdleDisplaySleep])
        XCTAssertNotNil(preventer.expiresAt, "the session keeps its timer")

        preventer.keepDisplayOn = false
        types = redeyeAssertions().map { $0[kIOPMAssertionTypeKey] as? String }
        XCTAssertEqual(types, [kIOPMAssertionTypePreventUserIdleSystemSleep])
    }

    func testChangingKeepDisplayOnWhileOffDoesNotActivate() {
        preventer.keepDisplayOn = true
        XCTAssertFalse(preventer.isActive)
        XCTAssertFalse(hasRedeyeAssertion())
    }

    func testKeepDisplayOnIsSaved() {
        preventer.keepDisplayOn = true
        XCTAssertTrue(defaults.bool(forKey: SleepPreventer.keepDisplayOnKey))
        XCTAssertTrue(makePreventer().keepDisplayOn)
    }

    // MARK: - Default durations

    func testFactoryDefaultDurations() {
        XCTAssertNil(preventer.defaultDuration(for: .awake))
        XCTAssertEqual(preventer.defaultDuration(for: .lidClosed), 24 * 60 * 60)
    }

    func testActivateWithoutDurationUsesDefault() throws {
        preventer.activate(.lidClosed)
        let expiresAt = try XCTUnwrap(preventer.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 24 * 60 * 60, accuracy: 2)
    }

    func testExplicitForeverOverridesDefault() {
        preventer.activate(.lidClosed, for: nil)
        XCTAssertEqual(preventer.mode, .lidClosed)
        XCTAssertNil(preventer.expiresAt)
    }

    func testChangedDefaultDurationsAreUsedAndSaved() throws {
        preventer.setDefaultDuration(60 * 60, for: .awake)
        preventer.setDefaultDuration(nil, for: .lidClosed)
        XCTAssertEqual(makePreventer().defaultDuration(for: .awake), 60 * 60)
        XCTAssertNil(makePreventer().defaultDuration(for: .lidClosed), "Forever is saved, not reset to 24 hours")

        preventer.toggle()
        let expiresAt = try XCTUnwrap(preventer.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 60 * 60, accuracy: 2)
        preventer.cycle()
        XCTAssertEqual(preventer.mode, .lidClosed)
        XCTAssertNil(preventer.expiresAt)
    }

    // MARK: - Safety

    func testSafetyCutoffsAreOffByDefault() {
        XCTAssertFalse(preventer.batteryCutoff)
        XCTAssertFalse(preventer.heatCutoff)
        XCTAssertEqual(preventer.batteryCutoffPercent, 20)

        power.state = PowerState(batteryPercent: 5, onBattery: true, thermalState: .critical)
        preventer.activate(.lidClosed)
        XCTAssertEqual(preventer.mode, .lidClosed)
        power.state.batteryPercent = 4
        XCTAssertEqual(preventer.mode, .lidClosed)
    }

    func testBatteryCutoffStopsBelowThreshold() {
        var errors: [Error] = []
        preventer.onError = { errors.append($0) }
        preventer.batteryCutoff = true
        power.state = PowerState(batteryPercent: 25, onBattery: true, thermalState: .nominal)
        preventer.activate(.lidClosed)
        XCTAssertEqual(preventer.mode, .lidClosed)

        power.state.batteryPercent = 20
        XCTAssertEqual(preventer.mode, .lidClosed, "at the cutoff isn't below it")
        power.state.batteryPercent = 19
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertFalse(helper.sleepDisabled)
        XCTAssertFalse(hasRedeyeAssertion())
        XCTAssertEqual(errors as? [SafetyStop], [.lowBattery(20)])
    }

    func testBatteryCutoffIgnoredWhileCharging() {
        preventer.batteryCutoff = true
        power.state = PowerState(batteryPercent: 5, onBattery: false, thermalState: .nominal)
        preventer.activate()
        XCTAssertEqual(preventer.mode, .awake)

        power.state.onBattery = true  // unplugged
        XCTAssertEqual(preventer.mode, .off)
    }

    func testBatteryCutoffIgnoredWithoutBattery() {
        preventer.batteryCutoff = true
        power.state = PowerState(batteryPercent: nil, onBattery: false, thermalState: .nominal)
        preventer.activate()
        XCTAssertEqual(preventer.mode, .awake)
    }

    func testBatteryCutoffPercentIsUsedAndSaved() {
        preventer.batteryCutoff = true
        preventer.batteryCutoffPercent = 50
        XCTAssertEqual(makePreventer().batteryCutoffPercent, 50)
        XCTAssertTrue(makePreventer().batteryCutoff)
        power.state = PowerState(batteryPercent: 45, onBattery: true, thermalState: .nominal)
        preventer.activate()
        XCTAssertEqual(preventer.mode, .off)
    }

    func testHeatCutoffStopsWhenSeriousOrCritical() {
        var errors: [Error] = []
        preventer.onError = { errors.append($0) }
        preventer.heatCutoff = true
        preventer.activate(.lidClosed)
        power.state.thermalState = .fair
        XCTAssertEqual(preventer.mode, .lidClosed)
        power.state.thermalState = .serious
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertFalse(helper.sleepDisabled)

        preventer.activate()
        power.state.thermalState = .critical
        XCTAssertEqual(errors as? [SafetyStop], [.tooHot, .tooHot])
    }

    func testActivatingWhenUnsafeIsRefused() {
        var errors: [Error] = []
        preventer.onError = { errors.append($0) }
        preventer.heatCutoff = true
        power.state.thermalState = .serious
        preventer.cycle()
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertEqual(helper.requests, [], "the helper isn't even asked")
        XCTAssertFalse(hasRedeyeAssertion())
        XCTAssertEqual(errors as? [SafetyStop], [.tooHot])
    }

    func testTurningOnCutoffWhenAlreadyUnsafeStops() {
        power.state = PowerState(batteryPercent: 10, onBattery: true, thermalState: .nominal)
        preventer.activate()
        preventer.batteryCutoff = true
        XCTAssertEqual(preventer.mode, .off)
    }

    func testSafetyCancelsPendingLidClosedRequest() {
        helper.holdReplies = true
        preventer.heatCutoff = true
        preventer.activate(.lidClosed)
        power.state.thermalState = .critical
        helper.reply()
        XCTAssertEqual(preventer.mode, .off)
        XCTAssertEqual(helper.requests, [true, false])
        XCTAssertFalse(helper.sleepDisabled)
    }

    func testSafetyIgnoredWhileSleepingNormally() {
        var errors: [Error] = []
        preventer.onError = { errors.append($0) }
        preventer.heatCutoff = true
        power.state.thermalState = .critical
        XCTAssertTrue(errors.isEmpty)
    }

    func testRealPowerMonitorReadsState() {
        let state = PowerMonitor().state
        if let percent = state.batteryPercent {
            XCTAssertTrue((0...100).contains(percent))
        } else {
            XCTAssertFalse(state.onBattery, "no battery but running on one")
        }
    }
}
