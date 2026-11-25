import Foundation
import Security
import ServiceManagement

/// Turns system sleep fully off and on again, including lid-close sleep. Faked in tests.
protocol SleepDisabling: AnyObject {
    /// Calls `completion` on the main thread with nil on success. A request to disable sleep that's
    /// overtaken by a request to allow it may never complete.
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

/// The helper's launchd registration. `SMAppService` in the app, faked in tests.
protocol HelperRegistering: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: HelperRegistering {}

/// The XPC connection to the helper. Faked in tests.
protocol HelperConnecting: AnyObject {
    var isConnected: Bool { get }
    /// Called on the main thread when an open connection drops.
    var onConnectionLost: (() -> Void)? { get set }
    /// Calls `reply` on the main thread, or never if the helper doesn't get the request.
    func send(_ disabled: Bool, reply: @escaping @MainActor (Error?) -> Void)
    /// Drops the connection without calling `onConnectionLost`. The helper turns sleep back on.
    func reset()
}

/// Registers the privileged helper (`RedeyeHelper`) with `SMAppService.daemon` and asks it to run
/// `pmset -a disablesleep`. The helper turns sleep back on whenever its connection drops, so a crash
/// or force-quit of Redeye can't leave the Mac unable to sleep.
final class LidSleepHelper: SleepDisabling {
    static let plistName = "\(helperMachServiceName).plist"
    /// The helper answers in well under a second once it runs.
    static let replyTimeout: TimeInterval = 5

    var onConnectionLost: (() -> Void)?

    private let service: HelperRegistering
    private let connection: HelperConnecting
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let helperHash: () -> String?
    private let replyTimeout: TimeInterval
    /// How often, and how far apart, to try registering again right after unregistering.
    private let registerRetries = 10
    private let registerRetryDelay: TimeInterval

    /// Bumped by every request, so work for a request that was overtaken stops.
    private var request = 0
    /// Bumped when a try to disable sleep gets its answer (reply, error, drop or timeout).
    private var tryCount = 0
    /// Fails the try still waiting for the helper, if any.
    private var failWaitingTry: (@MainActor (Error) -> Void)?

    init(
        service: HelperRegistering = SMAppService.daemon(plistName: LidSleepHelper.plistName),
        connection: HelperConnecting = XPCHelperConnection(),
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        helperHash: (() -> String?)? = nil,
        replyTimeout: TimeInterval = LidSleepHelper.replyTimeout,
        registerRetryDelay: TimeInterval = 0.5
    ) {
        self.registerRetryDelay = registerRetryDelay
        self.service = service
        self.connection = connection
        self.defaults = defaults
        self.bundle = bundle
        self.helperHash = helperHash ?? { LidSleepHelper.helperCodeHash(in: bundle) }
        self.replyTimeout = replyTimeout
        connection.onConnectionLost = { [weak self] in
            guard let self else { return }
            if let fail = failWaitingTry {
                fail(LidSleepError.failed("it stopped."))
            } else {
                onConnectionLost?()
            }
        }
    }

    func setSleepDisabled(_ disabled: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        request += 1
        failWaitingTry = nil
        guard disabled else {
            // Never connected (or reset), so the helper isn't holding anything for us.
            guard connection.isConnected else { return completion(nil) }
            return connection.send(false, reply: completion)
        }
        let id = request
        ensureRegistered { [weak self] error in
            guard let self, id == request else { return }
            if let error { return completion(error) }
            disableSleep(request: id, retry: true, completion: completion)
        }
    }

    /// Asks the helper to disable sleep. launchd only starts the helper build it registered, and
    /// otherwise holds the request with no reply and no error. So if the helper doesn't answer in
    /// time, register this build again and try once more.
    private func disableSleep(request id: Int, retry: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        tryCount += 1
        let thisTry = tryCount
        let finish: @MainActor (Error?) -> Void = { [weak self] error in
            guard let self, thisTry == tryCount, id == request else { return }
            tryCount += 1
            failWaitingTry = nil
            guard let error else { return completion(nil) }
            // Drop the request so it can't take effect late. The helper turns sleep back on.
            connection.reset()
            guard retry else { return completion(error) }
            NSLog("Redeye: helper didn't answer (\(error.localizedDescription)), registering it again")
            reregister { [weak self] error in
                guard let self, id == request else { return }
                if let error { return completion(error) }
                disableSleep(request: id, retry: false, completion: completion)
            }
        }
        failWaitingTry = { finish($0) }
        connection.send(true, reply: finish)
        Timer.scheduledTimer(withTimeInterval: replyTimeout, repeats: false) { _ in
            MainActor.assumeIsolated { finish(LidSleepError.failed("it didn't start.")) }
        }
    }

    /// Registers the helper the first time (macOS then asks the user to approve it in System Settings),
    /// and again if it changed since.
    private func ensureRegistered(completion: @escaping @MainActor (Error?) -> Void) {
        switch service.status {
        case .enabled:
            helperChanged ? reregister(completion: completion) : completion(nil)
        case .requiresApproval:
            completion(LidSleepError.needsApproval)
        default:
            // A daemon that was never registered often reports .notFound rather than .notRegistered,
            // so only call it missing if the plist really isn't in the bundle.
            let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(Self.plistName)")
            guard FileManager.default.fileExists(atPath: plist.path) else {
                return completion(LidSleepError.helperMissing)
            }
            completion(register())
        }
    }

    // MARK: - Keeping the registration current

    static let registeredHashKey = "registeredHelperHash"

    /// Call at launch. If the helper was replaced since it was registered, re-registering reloads it,
    /// and the helper turns sleep back on as it starts. That covers a Mac restarted with sleep still
    /// disabled after Redeye was updated, since launchd won't run the replaced helper at boot.
    static func refreshRegistration() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        LidSleepHelper().refreshRegistration()
    }

    func refreshRegistration() {
        guard service.status == .enabled, helperChanged else { return }
        reregister { _ in }
    }

    /// Whether the helper in this copy of Redeye differs from the one last registered. Each ad-hoc
    /// signed build is different.
    private var helperChanged: Bool {
        guard let current = helperHash() else { return false }
        return current != defaults.string(forKey: Self.registeredHashKey)
    }

    /// Unregisters and registers again, so launchd runs this copy's helper build. For about half a
    /// second after unregistering, Background Task Management still has the helper marked disabled and
    /// `register()` fails ("Job is not allowed to bootstrap", SMAppService error 1), so keep trying.
    private func reregister(completion: @escaping @MainActor (Error?) -> Void) {
        NSLog("Redeye: registering the helper again")
        defaults.removeObject(forKey: Self.registeredHashKey)
        Task { [self] in
            do {
                try await service.unregister()
            } catch {
                NSLog("Redeye: helper unregistration: \(error.localizedDescription)")
            }
            var error = register()
            for _ in 0..<registerRetries where error != nil && service.status != .requiresApproval {
                try? await Task.sleep(for: .seconds(registerRetryDelay))
                error = register()
            }
            completion(error)
        }
    }

    /// Registers the helper, and remembers which build only once launchd has really taken it, so a
    /// failed registration is tried again next time.
    private func register() -> Error? {
        do {
            try service.register()
        } catch {
            NSLog("Redeye: helper registration: \(error.localizedDescription)")
            if service.status != .requiresApproval {
                return LidSleepError.failed(error.localizedDescription)
            }
        }
        guard service.status == .enabled else { return LidSleepError.needsApproval }
        defaults.set(helperHash(), forKey: Self.registeredHashKey)
        return nil
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

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The real XPC connection to `RedeyeHelper`.
final class XPCHelperConnection: HelperConnecting {
    var onConnectionLost: (() -> Void)?
    private var connection: NSXPCConnection?

    var isConnected: Bool { connection != nil }

    func send(_ disabled: Bool, reply: @escaping @MainActor (Error?) -> Void) {
        // XPC calls this on its own queue, so it mustn't inherit main-actor isolation.
        let proxy = connect().remoteObjectProxyWithErrorHandler { @Sendable error in
            DispatchQueue.main.async { reply(LidSleepError.failed(error.localizedDescription)) }
        } as? HelperProtocol
        proxy?.setSleepDisabled(disabled) { ok in
            DispatchQueue.main.async { reply(ok ? nil : LidSleepError.failed("pmset failed")) }
        }
    }

    func reset() {
        let old = connection
        connection = nil
        old?.invalidate()
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        let id = ObjectIdentifier(connection)
        let lost: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                // Ignore connections that were already reset or replaced.
                guard let self, let current = self.connection, ObjectIdentifier(current) == id else { return }
                self.connection = nil
                current.invalidate()
                self.onConnectionLost?()
            }
        }
        connection.interruptionHandler = lost
        connection.invalidationHandler = lost
        connection.resume()
        self.connection = connection
        return connection
    }
}
