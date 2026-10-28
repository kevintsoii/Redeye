import Foundation

/// Mach service and launchd label of the privileged helper that runs `pmset disablesleep`.
nonisolated let helperMachServiceName = "com.kevin.redeye.helper"

/// What Redeye can ask the helper over XPC. Compiled into both the app and the helper.
@objc(RedeyeHelperProtocol)
nonisolated protocol HelperProtocol {
    /// Turns `pmset -a disablesleep` on or off for this connection. Replies true on success.
    /// Sleep is turned back on when the last connection asking for it lets go or disconnects.
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
}
