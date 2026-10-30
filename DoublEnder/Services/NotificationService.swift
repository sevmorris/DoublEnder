import Foundation
import UserNotifications
import AppKit

/// Local notifications for the "recording saved" event. Singleton because
/// UNUserNotificationCenter holds the delegate weakly and the action category
/// only needs to be registered once at app launch.
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private static let categoryID = "RECORDING_SAVED"
    private static let revealActionID = "REVEAL_ACTION"
    private static let filePathKey = "filePath"

    private override init() {
        super.init()
    }

    /// Install ourselves as the center's delegate and register the action
    /// category so the "Reveal in Finder" button appears on every recording
    /// notification. Call once at app launch.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reveal = UNNotificationAction(
            identifier: Self.revealActionID,
            title: "Reveal in Finder",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [reveal],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Best-effort authorization prompt. Safe to call repeatedly — the system
    /// shows the modal on the first call only.
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Post a "recording saved" notification carrying the file path so the
    /// Reveal in Finder action can locate it.
    func postRecordingSaved(fileURL: URL) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized
                   || settings.authorizationStatus == .provisional
        guard allowed else { return }

        let content = UNMutableNotificationContent()
        content.title = "DoublEnder"
        content.body = "\(fileURL.lastPathComponent) — recording saved."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.filePathKey: fileURL.path]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Tapping the body of the notification or the Reveal in Finder action
    /// both jump to the file in Finder.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.revealActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if let path = response.notification.request.content.userInfo[Self.filePathKey] as? String {
                let url = URL(fileURLWithPath: path)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        completionHandler()
    }

    /// Show the banner + sound even when DoublEnder itself is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
