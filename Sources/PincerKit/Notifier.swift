import Foundation
import UserNotifications

/// Local notifications for replies, background activity and exec approvals, posted while the app
/// is connected. On iOS, `PushRegistrar` covers the time Pincer is suspended or closed: while a
/// gateway's push is active, local notifications for it stop once the app leaves the foreground,
/// and pushes that arrive in the foreground are hidden while the gateway is connected.
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Shared so the iOS app delegate can install it before launch finishes, which is when a
    /// notification that launched the app is delivered.
    public static let shared = Notifier()

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
    public var onOpen: ((Target) -> Void)? {
        didSet {
            guard let onOpen, let target = self.pendingOpen else { return }
            self.pendingOpen = nil
            onOpen(target)
        }
    }
    /// Whether push delivers this gateway's notifications while the app isn't active.
    public var pushDelivers: (UUID) -> Bool = { _ in false }
    /// Whether the app is live on this gateway, so a push arriving in the foreground is redundant.
    public var isConnected: (UUID) -> Bool = { _ in false }
    private var pendingOpen: Target?
    private var pendingApproval: (UUID, String, String)?
    private var activated = false

    private var recent: [String] = []
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter traps without a bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override public init() {
        super.init()
    }

    public func activate() {
        guard let center, !self.activated else { return }
        self.activated = true
        center.delegate = self
        let approve = UNNotificationAction(identifier: "approve-once", title: "Allow once")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        // Pushes can arrive while Pincer isn't running, so their actions open the app (which
        // connects, then resolves the approval) and require unlocking the device first.
        let pushApprove = UNNotificationAction(
            identifier: "approve-once", title: "Allow once", options: [.foreground, .authenticationRequired])
        let pushDeny = UNNotificationAction(
            identifier: "deny", title: "Deny", options: [.foreground, .authenticationRequired, .destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "reply", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "approval", actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "approval-push", actions: [pushApprove, pushDeny], intentIdentifiers: []),
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
        guard self.enabled, let center, !self.deferredToPush(gateway.id) else { return }
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

    /// In the background the push for the same event is on its way; posting too would double it.
    public func deferredToPush(_ gatewayId: UUID) -> Bool {
        !self.appIsActive && self.pushDelivers(gatewayId)
    }

    private func title(row: SessionRow, gateway: GatewayStore) -> String {
        let agent = gateway.agent(row.agentId)
        let prefix = agent.emoji.map { "\($0) " } ?? ""
        return "\(prefix)\(row.title) · \(agent.name)"
    }

    private func post(id: String, title: String, body: String, target: Target, category: String) {
        guard self.enabled, let center, !self.deferredToPush(target.gatewayId) else { return }
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
    public var onApprovalAction: ((UUID, String, String) -> Void)? {
        didSet {
            guard let onApprovalAction, let pending = self.pendingApproval else { return }
            self.pendingApproval = nil
            onApprovalAction(pending.0, pending.1, pending.2)
        }
    }

    /// The gateway a notification belongs to: ours carry `gateway`; an undecrypted push only `pincer.g`.
    nonisolated static func gatewayId(_ info: [AnyHashable: Any]) -> UUID? {
        let raw = info["gateway"] as? String ?? (info["pincer"] as? [String: Any])?["g"] as? String
        return raw.flatMap(UUID.init(uuidString:))
    }

    func handleResponse(gateway: UUID, session: String, approval: String?, action: String) {
        if let approval, action == "approve-once" || action == "deny" {
            let decision = action == "deny" ? "deny" : "allow-once"
            if let onApprovalAction = self.onApprovalAction {
                onApprovalAction(gateway, approval, decision)
            } else {
                self.pendingApproval = (gateway, approval, decision)
            }
        } else if !session.isEmpty {
            let target = Target(gatewayId: gateway, sessionKey: session)
            if let onOpen = self.onOpen { onOpen(target) } else { self.pendingOpen = target }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    {
        let info = notification.request.content.userInfo
        guard notification.request.trigger is UNPushNotificationTrigger, let gateway = Self.gatewayId(info) else {
            return [.banner, .list, .sound]
        }
        // While connected, the live stream already notified (or chose not to, for the open chat).
        let redundant = await MainActor.run { self.isConnected(gateway) }
        return redundant ? [] : [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async
    {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let gateway = Self.gatewayId(info) else { return }
        let session = info["session"] as? String ?? ""
        let approval = info["approval"] as? String
        await MainActor.run {
            self.handleResponse(gateway: gateway, session: session, approval: approval, action: action)
        }
    }
}
