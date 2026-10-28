import Foundation

// Redeye's privileged helper. launchd runs it as root (registered with SMAppService.daemon) so
// Redeye can keep the Mac awake with the lid closed via `pmset -a disablesleep 1`.
//
// disablesleep is a persistent system setting that outlives Redeye, so the helper always turns it
// back off: when the app asks, when the app's connection drops (quit, crash, force-kill), when the
// helper starts (after a reboot or a helper crash) and when launchd stops it.

/// Only Redeye itself may connect.
/// TODO: once releases are Developer ID signed, also require the team: `anchor apple generic and
/// certificate leaf[subject.OU] = "<TEAM_ID>"`.
let clientRequirement = #"identifier "com.kevin.redeye""#

/// How long to stay running with no connections before exiting. launchd relaunches on demand.
let idleExitDelay: TimeInterval = 10

@discardableResult
func setDisableSleep(_ disabled: Bool) -> Bool {
    let pmset = Process()
    pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    pmset.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
    do {
        try pmset.run()
        pmset.waitUntilExit()
    } catch {
        NSLog("RedeyeHelper: couldn't run pmset: \(error)")
        return false
    }
    let ok = pmset.terminationStatus == 0
    NSLog("RedeyeHelper: disablesleep \(disabled ? 1 : 0)\(ok ? "" : " failed (\(pmset.terminationStatus))")")
    return ok
}

@MainActor
enum Helper {
    static let sleepState = HelperSleepState(setDisableSleep: setDisableSleep)
    static var idleCheck = 0
}

/// Exits after `idleExitDelay` with no connections, turning sleep back on first just in case.
@MainActor
func scheduleIdleExit() {
    Helper.idleCheck += 1
    let check = Helper.idleCheck
    DispatchQueue.main.asyncAfter(deadline: .now() + idleExitDelay) {
        MainActor.assumeIsolated {
            guard check == Helper.idleCheck, Helper.sleepState.isIdle else { return }
            Helper.sleepState.restoreSleep()
            exit(0)
        }
    }
}

/// Runs on the main thread and waits, so state changes happen in order with the idle check.
func onMain(_ work: @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }
}

/// The object a single Redeye connection talks to.
final class Session: NSObject, HelperProtocol, Sendable {
    let id = UUID()

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        let id = id
        DispatchQueue.main.async {
            reply(MainActor.assumeIsolated { Helper.sleepState.set(disabled, for: id) })
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(clientRequirement)
        let session = Session()
        let id = session.id
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = session
        let gone: @Sendable () -> Void = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Helper.sleepState.disconnected(id)
                    scheduleIdleExit()
                }
            }
        }
        connection.invalidationHandler = gone
        connection.interruptionHandler = gone
        onMain { Helper.sleepState.connected(id) }
        connection.resume()
        return true
    }
}

// Start from a clean slate: nobody is connected yet, so nothing should be keeping the Mac awake.
// This also covers a reboot (RunAtLoad) or a helper crash (KeepAlive) while sleep was disabled.
MainActor.assumeIsolated { _ = Helper.sleepState.restoreSleep() }

signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    MainActor.assumeIsolated { _ = Helper.sleepState.restoreSleep() }
    exit(0)
}
sigterm.resume()

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()
MainActor.assumeIsolated { scheduleIdleExit() }
RunLoop.main.run()
