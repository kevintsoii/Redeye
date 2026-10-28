import AppKit

/// Keeps a second copy of Redeye from adding another menu bar icon.
enum SingleInstance {
    /// Other running apps with this bundle ID, not counting this process.
    static func otherInstances(
        of bundleID: String? = Bundle.main.bundleIdentifier,
        excluding pid: pid_t = getpid()
    ) -> [NSRunningApplication] {
        guard let bundleID else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != pid && !$0.isTerminated }
    }

    /// True if this copy should quit because another one is already running.
    /// Unit tests are hosted in the app, so they're allowed to run alongside it.
    static func shouldQuit(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        return !otherInstances().isEmpty
    }
}
