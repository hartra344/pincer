import Foundation
import UserNotifications

/// Local notifications for replies, background activity and exec approvals.
/// Everything is delivered while the app is running; there is no push relay.
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public struct Target: Hashable, Sendable {
        public let gatewayId: UUID
        public let sessionKey: String

        public init(gatewayId: UUID, sessionKey: String) {
            self.gatewayId = gatewayId
            self.sessionKey = sessionKey
        }
    }

    /// What the user is looking at right now; that session is never notified.
    public var visible: Target?
    public var appIsActive = true
    public var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "pincer.notifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pincer.notifications") }
    }
    public var onOpen: ((Target) -> Void)?

    private var recent: [String] = []
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter traps without a bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override public init() {
        super.init()
    }

    public func activate() {
        guard let center else { return }
        center.delegate = self
        let approve = UNNotificationAction(identifier: "approve-once", title: "Allow once")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "reply", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "approval", actions: [approve, deny], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyReply(row: SessionRow, text: String?, dedupe: String?, gateway: GatewayStore) {
        self.post(
            id: "reply:\(dedupe ?? "\(row.key):\(row.activityMs)")",
            title: self.title(row: row, gateway: gateway),
            body: Self.clip(text ?? "New reply"),
            target: Target(gatewayId: gateway.id, sessionKey: row.key),
            category: "reply")
    }

    func notifyActivity(row: SessionRow, gateway: GatewayStore) {
        self.post(
            id: "reply:\(row.key):\(Int(row.activityMs))",
            title: self.title(row: row, gateway: gateway),
            body: Self.clip(row.preview ?? "New activity"),
            target: Target(gatewayId: gateway.id, sessionKey: row.key),
            category: "reply")
    }

    func notifyApproval(_ approval: ExecApproval, gateway: GatewayStore) {
        guard self.enabled, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Approval needed · \(gateway.profile.name)"
        content.body = Self.clip(approval.command)
        content.sound = .default
        content.categoryIdentifier = "approval"
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            "gateway": gateway.id.uuidString,
            "session": approval.sessionKey ?? "",
            "approval": approval.id,
        ]
        center.add(UNNotificationRequest(identifier: "approval:\(approval.id)", content: content, trigger: nil))
    }

    private func title(row: SessionRow, gateway: GatewayStore) -> String {
        let agent = gateway.agent(row.agentId)
        let prefix = agent.emoji.map { "\($0) " } ?? ""
        return "\(prefix)\(row.title) · \(agent.name)"
    }

    private func post(id: String, title: String, body: String, target: Target, category: String) {
        guard self.enabled, let center else { return }
        if self.appIsActive, self.visible == target { return }
        let dedupeKey = id.hasPrefix("reply:") ? "\(target.sessionKey)|\(body.prefix(80))" : id
        guard !self.recent.contains(id), !self.recent.contains(dedupeKey) else { return }
        self.recent.append(contentsOf: [id, dedupeKey])
        if self.recent.count > 200 { self.recent.removeFirst(self.recent.count - 200) }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = "\(target.gatewayId.uuidString)|\(target.sessionKey)"
        content.userInfo = ["gateway": target.gatewayId.uuidString, "session": target.sessionKey]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    public func clear(target: Target) {
        guard let center else { return }
        let thread = "\(target.gatewayId.uuidString)|\(target.sessionKey)"
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    public func setBadge(_ count: Int) {
        self.center?.setBadgeCount(count)
    }

    static func clip(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return flattened.count > 220 ? String(flattened.prefix(219)) + "…" : flattened
    }

    /// Approval actions from the notification itself.
    public var onApprovalAction: ((UUID, String, String) -> Void)?

    // MARK: UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async
    {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let gateway = (info["gateway"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let session = info["session"] as? String ?? ""
        let approval = info["approval"] as? String
        await MainActor.run {
            if let approval, action == "approve-once" || action == "deny" {
                self.onApprovalAction?(gateway, approval, action == "deny" ? "deny" : "allow-once")
            } else if !session.isEmpty {
                self.onOpen?(Target(gatewayId: gateway, sessionKey: session))
            }
        }
    }
}
