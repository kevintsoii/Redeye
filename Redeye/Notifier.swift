import Foundation
import UserNotifications

/// Posts macOS notifications, e.g. when Redeye stops keeping the Mac awake on its own. Tests use
/// `FakeNotifier`.
protocol Notifying: AnyObject {
    /// Asks for permission the first time. Once the user has answered, macOS doesn't ask again.
    func requestAuthorization()
    func post(title: String, body: String)
}

/// Posts through `UNUserNotificationCenter`. Users can turn these off in System Settings > Notifications.
final class Notifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert]) { _, error in
            if let error { NSLog("Redeye: notification permission failed: \(error.localizedDescription)") }
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("Redeye: couldn't post notification: \(error.localizedDescription)") }
        }
    }

    /// Show banners even while Redeye is the active app, e.g. with Settings open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
