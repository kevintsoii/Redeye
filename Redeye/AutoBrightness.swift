import CoreGraphics
import Foundation

/// Turns automatic brightness off and back on. When auto-brightness is on and you change the
/// brightness by hand, macOS keeps your level instead of following the light sensor; switching
/// auto-brightness off and on again hands control back to the sensor. Tests use `FakeAutoBrightness`.
protocol AutoBrightnessResetting: AnyObject {
    /// Some connected display has an ambient light sensor (e.g. a MacBook's built-in screen).
    var isAvailable: Bool { get }
    /// Turns auto-brightness off, then on, for every display that supports it. Ends with it on.
    func reset()
}

/// Uses the private DisplayServices framework (an Apple framework, not a public API).
/// No root needed. If the symbols ever disappear, `isAvailable` is false and the menu item hides.
final class AutoBrightness: AutoBrightnessResetting {
    private let displays: @MainActor () -> [CGDirectDisplayID]
    private let setEnabled: @MainActor (CGDirectDisplayID, Bool) -> Void
    private let pause: TimeInterval

    /// - Parameter pause: How long auto-brightness stays off, so macOS registers the change.
    init(
        displays: @escaping @MainActor () -> [CGDirectDisplayID] = AutoBrightness.sensorDisplays,
        setEnabled: @escaping @MainActor (CGDirectDisplayID, Bool) -> Void = AutoBrightness.setEnabled,
        pause: TimeInterval = 0.5
    ) {
        self.displays = displays
        self.setEnabled = setEnabled
        self.pause = pause
    }

    var isAvailable: Bool {
        !displays().isEmpty
    }

    func reset() {
        let ids = displays()
        guard !ids.isEmpty else { return }
        ids.forEach { setEnabled($0, false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [setEnabled] in
            MainActor.assumeIsolated {
                ids.forEach { setEnabled($0, true) }
            }
        }
    }

    // MARK: - DisplayServices

    private typealias HasSensor = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Enable = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static let hasSensor: HasSensor? = symbol("DisplayServicesHasAmbientLightCompensation")
    private static let enable: Enable? = symbol("DisplayServicesEnableAmbientLightCompensation")

    private static func symbol<T>(_ name: String) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Online displays with an ambient light sensor. Empty if DisplayServices isn't usable.
    static func sensorDisplays() -> [CGDirectDisplayID] {
        guard let hasSensor, enable != nil else { return [] }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { hasSensor($0) }
    }

    static func setEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) {
        guard let enable else { return }
        let result = enable(display, enabled)
        if result != 0 {
            NSLog("Redeye: couldn't turn auto-brightness \(enabled ? "on" : "off") for display \(display) (\(result))")
        }
    }
}
