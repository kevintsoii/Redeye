import AppKit
import IOKit.pwr_mgt
import ServiceManagement
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

/// Counts resets instead of touching the real display.
@MainActor
final class FakeAutoBrightness: AutoBrightnessResetting {
    var isAvailable = true
    private(set) var resets = 0

    func reset() {
        resets += 1
    }
}

/// Stands in for the helper's launchd registration.
@MainActor
final class FakeHelperService: HelperRegistering {
    var status: SMAppService.Status = .enabled
    /// What `status` becomes after a successful `register()`.
    var statusAfterRegister: SMAppService.Status = .enabled
    /// How many of the next `register()` calls fail, leaving `status` unchanged, like right after
    /// unregistering while Background Task Management catches up.
    var failingRegisters = 0
    /// "register" and "unregister", in order.
    private(set) var calls: [String] = []

    func register() throws {
        calls.append("register")
        if failingRegisters > 0 {
            failingRegisters -= 1
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
        }
        status = statusAfterRegister
    }

    func unregister() async throws {
        calls.append("unregister")
        status = .notRegistered
    }
}

/// Stands in for the XPC connection to the helper.
@MainActor
final class FakeHelperConnection: HelperConnecting {
    enum Answer { case reply, silent }

    var onConnectionLost: (() -> Void)?
    private(set) var isConnected = false
    /// Every request, in order.
    private(set) var sent: [Bool] = []
    private(set) var resets = 0
    /// How the helper answers each request to disable sleep, in order. Replies once these run out.
    /// `.silent` is a helper launchd won't start: the request waits forever.
    var answers: [Answer] = []

    func send(_ disabled: Bool, reply: @escaping @MainActor (Error?) -> Void) {
        isConnected = true
        sent.append(disabled)
        if disabled, !answers.isEmpty, answers.removeFirst() == .silent { return }
        reply(nil)
    }

    func reset() {
        isConnected = false
        resets += 1
    }

    /// The connection drops on its own.
    func drop() {
        isConnected = false
        onConnectionLost?()
    }
}

/// Spins the main run loop until `condition` holds or `timeout` passes.
@MainActor
func runMainLoop(until condition: () -> Bool, timeout: TimeInterval = 2) {
    let end = Date().addingTimeInterval(timeout)
    while !condition(), Date() < end {
        runMainLoop(for: 0.01)
    }
}
