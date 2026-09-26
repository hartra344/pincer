import PincerPush
import UserNotifications

/// Decrypts Gateway Web Push messages that the Pincer relay forwarded through APNs, and turns
/// them into the same notifications the app posts itself: one thread per chat, and actions for
/// exec approvals. If the keys are missing (e.g. the gateway was removed), the relay's generic
/// alert is shown unchanged.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void)
    {
        self.contentHandler = contentHandler
        self.fallback = request.content
        guard let message = PushMessage(apnsPayload: request.content.userInfo),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else {
            contentHandler(request.content)
            return
        }
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = message.threadIdentifier
        content.categoryIdentifier = message.categoryIdentifier
        content.userInfo = message.userInfo
        if case .approval(_, true) = message.kind { content.interruptionLevel = .timeSensitive }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let fallback { contentHandler(fallback) }
    }
}
