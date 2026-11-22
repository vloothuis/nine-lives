import Foundation
import UserNotifications

@MainActor
public final class Notifier {
    public init() {}

    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func post(title: String, body: String, id: String = UUID().uuidString, sound: Bool = false) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
