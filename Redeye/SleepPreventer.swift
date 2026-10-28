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

/// Why the Safety settings let the Mac sleep.
enum SafetyStop: LocalizedError, Equatable {
    /// On battery and below the cutoff, which is the associated percentage.
    case lowBattery(Int)
    case tooHot

    var errorDescription: String? {
        switch self {
        case .lowBattery(let cutoff): "The battery is below \(cutoff)%, so Redeye is letting your Mac sleep. You can change this in Settings > Safety."
        case .tooHot: "Your Mac is too hot, so Redeye is letting it sleep. You can change this in Settings > Safety."
        }
    }
}

/// Why an awake mode ended without the user turning it off, e.g. while they're away. Shown as a notification.
enum AutoStop: Equatable {
    /// The timer ran out. The associated mode is the one that ended.
    case expired(SleepMode)
    case safety(SafetyStop)
    /// The helper went away during Stay Awake (Ignore Lid).
    case helperLost

    var title: String {
        switch self {
        case .expired(.lidClosed): "Stay Awake (Ignore Lid) ended"
        case .expired: "Stay Awake ended"
        case .safety: "Redeye is letting your Mac sleep"
        case .helperLost: "Stay Awake (Ignore Lid) stopped"
        }
    }

    var message: String {
        switch self {
        case .expired: "The timer ran out, so your Mac can sleep again."
        case .safety(let stop): stop.localizedDescription
        case .helperLost: "Redeye's helper stopped, so your Mac can sleep again."
        }
    }
}

/// Holds an IOKit power assertion, and in lid-closed mode the helper's `disablesleep`, plus the
/// expiry timer. By default the display may sleep while the system stays awake (`caffeinate -i`).
final class SleepPreventer {
    static let keepDisplayOnKey = "keepDisplayOn"
    static let batteryCutoffKey = "batteryCutoff"
    static let batteryCutoffPercentKey = "batteryCutoffPercent"
    static let heatCutoffKey = "heatCutoff"

    /// The durations offered in the menu and in Settings. nil is Forever.
    static let durations: [(title: String, duration: TimeInterval?)] = [
        ("Forever", nil),
        ("30 Minutes", 30 * 60),
        ("1 Hour", 60 * 60),
        ("6 Hours", 6 * 60 * 60),
        ("12 Hours", 12 * 60 * 60),
        ("24 Hours", 24 * 60 * 60),
    ]
    static let batteryCutoffPercents = [10, 20, 30, 40, 50]

    static func defaultDurationKey(for mode: SleepMode) -> String {
        "\(mode)DefaultDuration"
    }

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?
    private let defaults: UserDefaults
    private let sleepDisabler: SleepDisabling
    private let powerMonitor: PowerMonitoring
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

    /// Let the Mac sleep when it's on battery below `batteryCutoffPercent`. Off by default.
    var batteryCutoff: Bool {
        get { defaults.bool(forKey: Self.batteryCutoffKey) }
        set {
            defaults.set(newValue, forKey: Self.batteryCutoffKey)
            checkSafety()
        }
    }

    var batteryCutoffPercent: Int {
        get { defaults.object(forKey: Self.batteryCutoffPercentKey) as? Int ?? 20 }
        set {
            defaults.set(newValue, forKey: Self.batteryCutoffPercentKey)
            checkSafety()
        }
    }

    /// Let the Mac sleep when macOS reports serious or critical thermal pressure. Off by default.
    var heatCutoff: Bool {
        get { defaults.bool(forKey: Self.heatCutoffKey) }
        set {
            defaults.set(newValue, forKey: Self.heatCutoffKey)
            checkSafety()
        }
    }

    /// Called whenever the mode changes (including timer expiry).
    var onChange: (() -> Void)?
    /// Called when a mode couldn't start: the helper failed, or a Safety setting refused it.
    var onError: ((Error) -> Void)?
    /// Called after an active mode ended on its own: timer, Safety setting or lost helper.
    var onAutoStop: ((AutoStop) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        sleepDisabler: SleepDisabling = LidSleepHelper(),
        powerMonitor: PowerMonitoring = PowerMonitor()
    ) {
        self.defaults = defaults
        self.sleepDisabler = sleepDisabler
        self.powerMonitor = powerMonitor
        powerMonitor.onChange = { [weak self] in self?.checkSafety() }
        sleepDisabler.onConnectionLost = { [weak self] in
            guard let self, askedHelperToDisable else { return }
            askedHelperToDisable = false
            let wasLidClosed = mode == .lidClosed
            deactivate()
            if wasLidClosed {
                onAutoStop?(.helperLost)
            } else {
                onError?(LidSleepError.failed("it stopped, so sleep is allowed again."))
            }
        }
    }

    /// How long left-click, toggle and URLs without a duration keep the Mac awake in `mode`. nil is
    /// Forever. Stay Awake defaults to Forever, Stay Awake (Ignore Lid) to 24 hours.
    func defaultDuration(for mode: SleepMode) -> TimeInterval? {
        guard let seconds = defaults.object(forKey: Self.defaultDurationKey(for: mode)) as? Double else {
            return mode == .lidClosed ? 24 * 60 * 60 : nil
        }
        return seconds > 0 ? seconds : nil
    }

    /// Saved as seconds, with 0 for Forever.
    func setDefaultDuration(_ duration: TimeInterval?, for mode: SleepMode) {
        defaults.set(duration ?? 0, forKey: Self.defaultDurationKey(for: mode))
    }

    /// Why the Safety settings say the Mac should be allowed to sleep right now, if they do.
    func safetyStop() -> SafetyStop? {
        let state = powerMonitor.state
        if heatCutoff && state.isTooHot { return .tooHot }
        if batteryCutoff, state.onBattery, let percent = state.batteryPercent, percent < batteryCutoffPercent {
            return .lowBattery(batteryCutoffPercent)
        }
        return nil
    }

    /// Stops and reports when a Safety setting says to, including while waiting for the helper.
    /// Ending an active mode is an `AutoStop`; cancelling a start that's still waiting is an error.
    private func checkSafety() {
        guard isActive || askedHelperToDisable, let stop = safetyStop() else { return }
        let wasActive = isActive
        deactivate()
        if wasActive {
            onAutoStop?(.safety(stop))
        } else {
            onError?(stop)
        }
    }

    /// Start preventing sleep in the given mode for its default duration.
    func activate(_ mode: SleepMode = .awake) {
        activate(mode, for: defaultDuration(for: mode))
    }

    /// Start preventing sleep in the given mode. Pass nil for Forever.
    /// Stay Awake (Ignore Lid) waits for the helper; if it fails, Redeye falls back to Sleep Normally.
    /// Refused, with `onError`, if a Safety setting already says to let the Mac sleep.
    func activate(_ mode: SleepMode = .awake, for duration: TimeInterval?) {
        guard mode != .off else { return deactivate() }
        if let stop = safetyStop() {
            deactivate()
            onError?(stop)
            return
        }
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
                MainActor.assumeIsolated { self?.expire() }
            }
        }
        onChange?()
    }

    private func expire() {
        let ended = mode
        deactivate()
        onAutoStop?(.expired(ended))
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

    /// Sleep Normally ↔ Stay Awake, for its default duration. Used by the URL scheme.
    func toggle() {
        isActive ? deactivate() : activate()
    }

    /// Sleep Normally → Stay Awake → Stay Awake (Ignore Lid) → Sleep Normally, each for its default
    /// duration. Used by left-click.
    func cycle() {
        activate(mode.next)
    }
}
