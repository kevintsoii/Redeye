import AppKit
import IOKit.pwr_mgt
import XCTest
@testable import Redeye

/// This process's power assertions created by SleepPreventer, as seen by powerd.
func redeyeAssertions() -> [[String: Any]] {
    var byProcess: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
          let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
          let mine = all[NSNumber(value: getpid())]
    else { return [] }
    return mine.filter { $0[kIOPMAssertionNameKey] as? String == "Redeye is keeping your Mac awake" }
}

func redeyeAssertionCount() -> Int {
    redeyeAssertions().count
}

func hasRedeyeAssertion() -> Bool {
    redeyeAssertionCount() > 0
}

/// Every descendant of `view` of the given type, depth first.
@MainActor
func descendants<T: NSView>(of view: NSView, ofType type: T.Type) -> [T] {
    view.subviews.flatMap { child -> [T] in
        let match = (child as? T).map { [$0] } ?? []
        return match + descendants(of: child, ofType: type)
    }
}

/// Spins the main run loop so scheduled timers can fire.
@MainActor
func runMainLoop(for seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Stands in for the privileged helper so tests never touch the real `disablesleep`.
@MainActor
final class FakeSleepDisabler: SleepDisabling {
    var onConnectionLost: (() -> Void)?
    /// Every request, in order.
    private(set) var requests: [Bool] = []
    /// Fail requests to disable sleep with this error.
    var error: Error?
    /// Hold replies until `reply()` instead of answering right away.
    var holdReplies = false
    private var pending: [() -> Void] = []

    /// What the helper would have set, counting only successful replies.
    private(set) var sleepDisabled = false

    func setSleepDisabled(_ disabled: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        requests.append(disabled)
        let error = disabled ? error : nil
        let answer = { [self] in
            if error == nil { sleepDisabled = disabled }
            completion(error)
        }
        if holdReplies {
            pending.append(answer)
        } else {
            answer()
        }
    }

    func reply() {
        let replies = pending
        pending = []
        replies.forEach { $0() }
    }
}

/// A throwaway defaults domain, removed after the test.
@MainActor
func makeTestDefaults(for test: XCTestCase) -> UserDefaults {
    let name = "RedeyeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    test.addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return defaults
}

/// Stands in for the battery and thermal readings. Changing `state` notifies like the real monitor.
@MainActor
final class FakePowerMonitor: PowerMonitoring {
    var onChange: (() -> Void)?
    var state = PowerState(batteryPercent: 80, onBattery: false, thermalState: .nominal) {
        didSet { onChange?() }
    }
}

/// Records notifications instead of posting them.
@MainActor
final class FakeNotifier: Notifying {
    private(set) var authorizationRequests = 0
    private(set) var posted: [(title: String, body: String)] = []

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func post(title: String, body: String) {
        posted.append((title, body))
    }
}
