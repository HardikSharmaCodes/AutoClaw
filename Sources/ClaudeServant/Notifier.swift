import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let askCategory = "ASK_WORK"
    static let askQuestion = "If you don't have any sessions to work on, should I work on existing projects?"

    var onAnswer: ((Bool) -> Void)?
    var onOpenAsk: (() -> Void)?
    private(set) var authorized = false

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let yes = UNNotificationAction(identifier: "YES", title: "Yes, work on projects", options: [])
        let no = UNNotificationAction(identifier: "NO", title: "No thanks", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: Self.askCategory, actions: [yes, no], intentIdentifiers: [], options: [])])
        c.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in self.authorized = granted }
    }

    func post(id: String = UUID().uuidString, title: String, body: String, ask: Bool = false, at date: Date? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if ask { content.categoryIdentifier = Self.askCategory }
        var trigger: UNNotificationTrigger?
        if let date, date.timeIntervalSinceNow > 1 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let isAsk = response.notification.request.content.categoryIdentifier == Self.askCategory
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case "YES": self.onAnswer?(true)
            case "NO": self.onAnswer?(false)
            case UNNotificationDefaultActionIdentifier where isAsk: self.onOpenAsk?()
            default: break
            }
        }
        completionHandler()
    }
}
