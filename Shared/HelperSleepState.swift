import Foundation

/// The helper's bookkeeping: which Redeye connections are open and which want sleep disabled.
/// `disablesleep` is on exactly while at least one connection wants it, and goes back off as soon as
/// none does, including when a connection drops because Redeye quit, crashed or was killed.
/// Compiled into the helper and the unit tests.
@MainActor
final class HelperSleepState {
    /// Runs `pmset -a disablesleep 1` or `0`. Returns true on success.
    private let setDisableSleep: (Bool) -> Bool
    private var connections = Set<UUID>()
    private var holders = Set<UUID>()

    init(setDisableSleep: @escaping (Bool) -> Bool) {
        self.setDisableSleep = setDisableSleep
    }

    var isIdle: Bool { connections.isEmpty }
    var isSleepDisabled: Bool { !holders.isEmpty }

    func connected(_ id: UUID) {
        connections.insert(id)
    }

    /// Returns false if sleep couldn't be changed. A failed request leaves the bookkeeping as it was.
    func set(_ disabled: Bool, for id: UUID) -> Bool {
        let wasDisabled = isSleepDisabled
        if disabled { holders.insert(id) } else { holders.remove(id) }
        guard isSleepDisabled != wasDisabled else { return true }

        if isSleepDisabled {
            guard setDisableSleep(true) else {
                holders.remove(id)
                return false
            }
            return true
        }
        return restoreSleep()
    }

    func disconnected(_ id: UUID) {
        connections.remove(id)
        _ = set(false, for: id)
    }

    /// Turns sleep back on, retrying because leaving it off is the one outcome that must not happen.
    @discardableResult
    func restoreSleep() -> Bool {
        holders.removeAll()
        for _ in 0..<3 {
            if setDisableSleep(false) { return true }
        }
        return false
    }
}
