import Foundation
import IOKit.ps
import notify

/// What the Safety settings look at: the battery and how hot the Mac is.
struct PowerState: Equatable {
    /// Charge of the internal battery, 0–100. nil on Macs without one.
    var batteryPercent: Int?
    /// Running on battery rather than a charger.
    var onBattery: Bool
    var thermalState: ProcessInfo.ThermalState

    /// macOS is throttling hard (serious or critical), e.g. in a bag.
    var isTooHot: Bool {
        thermalState == .serious || thermalState == .critical
    }
}

/// Reports the current `PowerState` and when it changes. Tests use `FakePowerMonitor`.
protocol PowerMonitoring: AnyObject {
    var state: PowerState { get }
    /// Called on the main thread when the battery, power source or thermal state changes.
    var onChange: (() -> Void)? { get set }
}

/// Watches IOKit power source notifications and `ProcessInfo` thermal state.
final class PowerMonitor: PowerMonitoring {
    var onChange: (() -> Void)?
    private var token: Int32 = 0

    init() {
        // Posted for any power source change: battery percentage, charger plugged in or out.
        notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        // Selector-based, so it's removed automatically when the monitor goes away.
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    deinit {
        notify_cancel(token)
    }

    /// Posted on whatever thread noticed the change.
    @objc nonisolated private func thermalStateChanged() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onChange?() }
        }
    }

    var state: PowerState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        var percent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            percent = current * 100 / max
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return PowerState(
            batteryPercent: percent,
            onBattery: providing == kIOPSBatteryPowerValue,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }
}
