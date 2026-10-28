import AppKit
import IOKit.pwr_mgt

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
