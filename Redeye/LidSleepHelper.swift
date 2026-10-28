import Foundation
import Security
import ServiceManagement

/// Turns system sleep fully off and on again, including lid-close sleep. Faked in tests.
protocol SleepDisabling: AnyObject {
    /// Calls `completion` on the main thread with nil on success.
    func setSleepDisabled(_ disabled: Bool, completion: @escaping @MainActor (Error?) -> Void)
    /// Called if the helper goes away while sleep is disabled. It turns sleep back on by itself.
    var onConnectionLost: (() -> Void)? { get set }
}

enum LidSleepError: LocalizedError {
    case needsApproval
    case helperMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsApproval:
            "Stay Awake (Ignore Lid) needs Redeye's helper. Turn on Redeye under Login Items & Extensions."
        case .helperMissing:
            "Redeye's helper is missing. Try downloading Redeye again."
        case .failed(let reason):
            "Redeye's helper failed: \(reason)"
        }
    }
}

/// Talks to the privileged helper (`RedeyeHelper`), registered with `SMAppService.daemon`, which runs
/// `pmset -a disablesleep`. The helper turns sleep back on whenever this connection drops, so a crash
/// or force-quit of Redeye can't leave the Mac unable to sleep.
final class LidSleepHelper: SleepDisabling {
    static let plistName = "\(helperMachServiceName).plist"

    var onConnectionLost: (() -> Void)?
    private let service = SMAppService.daemon(plistName: plistName)
    private var connection: NSXPCConnection?

    func setSleepDisabled(_ disabled: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        if disabled, let error = ensureRegistered() {
            completion(error)
            return
        }
        guard disabled || connection != nil else {
            completion(nil)  // never connected, so the helper isn't holding anything for us
            return
        }
        let proxy = connect().remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { completion(LidSleepError.failed(error.localizedDescription)) }
        } as? HelperProtocol
        proxy?.setSleepDisabled(disabled) { ok in
            DispatchQueue.main.async { completion(ok ? nil : LidSleepError.failed("pmset failed")) }
        }
    }

    /// Registers the daemon the first time. macOS then asks the user to approve it in System Settings.
    private func ensureRegistered() -> Error? {
        switch service.status {
        case .enabled:
            Self.reregisterIfHelperChanged(service)
            return service.status == .enabled ? nil : LidSleepError.needsApproval
        case .requiresApproval:
            return LidSleepError.needsApproval
        default:
            // A daemon that was never registered often reports .notFound rather than .notRegistered,
            // so only call it missing if the plist really isn't in the bundle.
            let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(Self.plistName)")
            guard FileManager.default.fileExists(atPath: plist.path) else { return LidSleepError.helperMissing }
            do {
                try service.register()
                UserDefaults.standard.set(Self.helperCodeHash(), forKey: Self.registeredHashKey)
            } catch {
                NSLog("Redeye: helper registration: \(error.localizedDescription)")
            }
            return service.status == .enabled ? nil : LidSleepError.needsApproval
        }
    }

    // MARK: - Keeping the registration current

    private static let registeredHashKey = "registeredHelperHash"

    /// Call at launch. If the helper was replaced since it was registered, re-registering reloads it,
    /// and the helper turns sleep back on as it starts. That covers a Mac restarted with sleep still
    /// disabled after Redeye was updated, since launchd won't run the replaced helper at boot.
    static func refreshRegistration() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let service = SMAppService.daemon(plistName: plistName)
        guard service.status == .enabled else { return }
        reregisterIfHelperChanged(service)
    }

    /// launchd only runs the exact helper build that was registered (for ad-hoc signed builds, every
    /// build is different) and otherwise fails to spawn it. Re-register when the helper has changed.
    private static func reregisterIfHelperChanged(_ service: SMAppService) {
        guard let current = helperCodeHash(),
              current != UserDefaults.standard.string(forKey: registeredHashKey)
        else { return }
        NSLog("Redeye: helper changed since it was registered, registering again")
        do {
            try service.unregister()
            try service.register()
            UserDefaults.standard.set(current, forKey: registeredHashKey)
        } catch {
            NSLog("Redeye: helper re-registration: \(error.localizedDescription)")
        }
    }

    /// The embedded helper's code directory hash, which changes whenever the helper does.
    static func helperCodeHash(in bundle: Bundle = .main) -> String? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/MacOS/RedeyeHelper")
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        let lost: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connection?.invalidate()
                self.connection = nil
                self.onConnectionLost?()
            }
        }
        connection.interruptionHandler = lost
        connection.invalidationHandler = lost
        connection.resume()
        self.connection = connection
        return connection
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
