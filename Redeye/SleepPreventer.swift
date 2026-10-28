import Foundation
import IOKit.pwr_mgt

/// How hard Redeye is keeping the Mac awake. Left-clicking the menu bar icon steps through these.
enum SleepMode: CaseIterable {
    /// Sleep Normally.
    case off
    /// Stay Awake: blocks idle sleep, like `caffeinate -i` (or `-d` with Keep display on). Closing the lid still sleeps.
    case awake
    /// Stay Awake (Ignore Lid): blocks all sleep, lid closed included, with `pmset disablesleep` through the privileged helper.
    case lidClosed

    var next: SleepMode {
        switch self {
        case .off: .awake
        case .awake: .lidClosed
        case .lidClosed: .off
        }
    }
}

/// Holds an IOKit power assertion, and in lid-closed mode the helper's `disablesleep`, plus the
/// expiry timer. By default the display may sleep while the system stays awake (`caffeinate -i`).
final class SleepPreventer {
    static let keepDisplayOnKey = "keepDisplayOn"

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?
    private let defaults: UserDefaults
    private let sleepDisabler: SleepDisabling
    /// Whether the helper was last asked to disable sleep, including requests still in flight.
    private var askedHelperToDisable = false
    /// Bumped on every change, so a late helper reply for an outdated request is ignored.
    private var generation = 0

    private(set) var mode: SleepMode = .off
    private(set) var expiresAt: Date?
    var isActive: Bool { mode != .off }

    /// Keep the display on too (`caffeinate -d`). Applies right away if already active.
    var keepDisplayOn: Bool {
        get { defaults.bool(forKey: Self.keepDisplayOnKey) }
        set {
            defaults.set(newValue, forKey: Self.keepDisplayOnKey)
            if isActive { createAssertion() }
        }
    }

    /// Called whenever the mode changes (including timer expiry).
    var onChange: (() -> Void)?
    /// Called when lid-closed mode couldn't start or stopped unexpectedly.
    var onError: ((Error) -> Void)?

    init(defaults: UserDefaults = .standard, sleepDisabler: SleepDisabling = LidSleepHelper()) {
        self.defaults = defaults
        self.sleepDisabler = sleepDisabler
        sleepDisabler.onConnectionLost = { [weak self] in
            guard let self, askedHelperToDisable else { return }
            askedHelperToDisable = false
            deactivate()
            onError?(LidSleepError.failed("it stopped, so sleep is allowed again."))
        }
    }

    /// Start preventing sleep in the given mode. Pass nil for indefinitely.
    /// Stay Awake (Ignore Lid) waits for the helper; if it fails, Redeye falls back to Sleep Normally.
    func activate(_ mode: SleepMode = .awake, for duration: TimeInterval? = nil) {
        guard mode != .off else { return deactivate() }
        guard mode == .lidClosed else { return apply(mode, for: duration) }

        generation += 1
        let request = generation
        askedHelperToDisable = true
        sleepDisabler.setSleepDisabled(true) { [weak self] error in
            guard let self, request == generation else { return }
            if let error {
                askedHelperToDisable = false
                deactivate()
                onError?(error)
            } else {
                apply(.lidClosed, for: duration)
            }
        }
    }

    private func apply(_ mode: SleepMode, for duration: TimeInterval?) {
        stop(keepHelper: mode == .lidClosed)
        guard createAssertion() else {
            stop(keepHelper: false)
            onChange?()
            return
        }
        self.mode = mode

        if let duration {
            expiresAt = Date().addingTimeInterval(duration)
            // Scheduled on the main run loop, so it fires on the main thread.
            expiryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate() }
            }
        }
        onChange?()
    }

    func deactivate(notify: Bool = true) {
        stop(keepHelper: false)
        if notify { onChange?() }
    }

    /// Releases everything. The helper is told to allow sleep again unless `keepHelper`.
    private func stop(keepHelper: Bool) {
        generation += 1
        expiryTimer?.invalidate()
        expiryTimer = nil
        expiresAt = nil
        releaseAssertion()
        mode = .off
        if !keepHelper && askedHelperToDisable {
            askedHelperToDisable = false
            sleepDisabler.setSleepDisabled(false) { error in
                if let error { NSLog("Redeye: couldn't re-enable sleep: \(error.localizedDescription)") }
            }
        }
    }

    /// Replaces any current assertion with one of the type the settings ask for.
    @discardableResult
    private func createAssertion() -> Bool {
        releaseAssertion()
        let type = keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Redeye is keeping your Mac awake" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            assertionID = 0
            NSLog("Redeye: failed to create power assertion (\(result))")
            return false
        }
        return true
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    /// Sleep Normally ↔ Stay Awake. Used by the URL scheme.
    func toggle() {
        isActive ? deactivate() : activate()
    }

    /// Sleep Normally → Stay Awake → Stay Awake (Ignore Lid) → Sleep Normally. Used by left-click.
    func cycle() {
        activate(mode.next)
    }
}
