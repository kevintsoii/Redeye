import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion that keeps the Mac awake while letting the display sleep.
/// This is the same mechanism `caffeinate -i` uses.
final class SleepPreventer {
    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?

    private(set) var expiresAt: Date?
    var isActive: Bool { assertionID != 0 }

    /// Called whenever the active state changes (including timer expiry).
    var onChange: (() -> Void)?

    /// Start preventing sleep. Pass nil for indefinitely.
    func activate(for duration: TimeInterval? = nil) {
        deactivate(notify: false)

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Redeye is keeping your Mac awake" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            assertionID = 0
            NSLog("Redeye: failed to create power assertion (\(result))")
            onChange?()
            return
        }

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
        expiryTimer?.invalidate()
        expiryTimer = nil
        expiresAt = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if notify { onChange?() }
    }

    func toggle() {
        isActive ? deactivate() : activate()
    }
}
