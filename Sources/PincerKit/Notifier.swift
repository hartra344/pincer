import Foundation
import Observation
import UserNotifications

/// Local notifications for replies, background activity, exec approvals and agent questions, posted while the app
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
    /// Chats shown in their own windows (#48); like `visible`, never notified while the app is active.
    public var windowVisible: Set<Target> = []
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
        center.setNotificationCategories(Set(Self.categories()))
        Task {
            // Only a first request shows the system prompt; the tips card waits it out (#332).
            let undecided = await center.notificationSettings().authorizationStatus == .notDetermined
            if undecided { NotificationPrompt.shared.isShowing = true }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            NotificationPrompt.shared.isShowing = false
        }
    }

    // MARK: Categories and actions

    public nonisolated static let replyCategory = "reply"
    /// Allow once, Always allow, Deny.
    public nonisolated static let approvalCategory = "approval"
    /// Allow once, Deny: for approvals whose `allowedDecisions` leave out `allow-always`.
    public nonisolated static let approvalOnceCategory = "approval-once"
    /// Pushes delivered before 1.x used this; kept registered so they keep their actions.
    public nonisolated static let legacyPushApprovalCategory = "approval-push"
    public nonisolated static let approvalCategories: Set<String> = [
        approvalCategory, approvalOnceCategory, legacyPushApprovalCategory,
    ]

    public nonisolated static let approveOnceAction = "approve-once"
    public nonisolated static let approveAlwaysAction = "approve-always"
    public nonisolated static let denyAction = "deny"

    /// Every category Pincer registers. None of the approval actions opens the app: they resolve in
    /// the background. Allowing requires unlocking the device; denying doesn't, since it can only
    /// stop a command. (`.authenticationRequired` has no effect on macOS.)
    public nonisolated static func categories() -> [UNNotificationCategory] {
        let once = UNNotificationAction(identifier: approveOnceAction, title: "Allow once", options: [.authenticationRequired])
        let always = UNNotificationAction(identifier: approveAlwaysAction, title: "Always allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive])
        return [
            UNNotificationCategory(identifier: replyCategory, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: approvalCategory, actions: [once, always, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: approvalOnceCategory, actions: [once, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: legacyPushApprovalCategory, actions: [once, always, deny], intentIdentifiers: []),
        ]
    }

    /// The `exec.approval.resolve` decision for a notification action, or nil for anything else
    /// (a plain tap, a dismissal, an unknown action).
    public nonisolated static func approvalDecision(for actionIdentifier: String) -> String? {
        switch actionIdentifier {
        case approveOnceAction: "allow-once"
        case approveAlwaysAction: "allow-always"
        case denyAction: "deny"
        default: nil
        }
    }

    /// The category for an approval's notification.
    public nonisolated static func category(for approval: ExecApproval) -> String {
        approval.allowsAlways ? approvalCategory : approvalOnceCategory
    }

    func notifyReply(row: SessionRow, text: String?, dedupe: String?, gateway: GatewayStore) {
        self.post(
            id: "reply:\(dedupe ?? "\(row.key):\(row.activityMs)")",
            title: self.title(row: row, gateway: gateway),
            body: Self.clip(text ?? "New reply"),
            target: Target(gatewayId: gateway.id, sessionKey: row.key),
            // The reply finished now; sessions.changed may not arrive before suspension.
            activityMs: max(row.activityMs, Date().timeIntervalSince1970 * 1000))
    }

    func notifyActivity(row: SessionRow, gateway: GatewayStore) {
        self.post(
            id: "reply:\(row.key):\(Int(row.activityMs))",
            title: self.title(row: row, gateway: gateway),
            body: Self.clip(row.preview ?? "New activity"),
            target: Target(gatewayId: gateway.id, sessionKey: row.key),
            activityMs: row.activityMs)
    }

    func notifyApproval(_ approval: ExecApproval, gateway: GatewayStore) {
        guard self.enabled, !self.deferredToPush(gateway.id) else { return }
        self.advanceRefreshCursor(gateway.id, approvalId: approval.id)
        guard let center else { return }
        center.add(Self.approvalRequest(approval, gatewayId: gateway.id, gatewayName: gateway.profile.name))
    }

    nonisolated static func approvalRequest(_ approval: ExecApproval, gatewayId: UUID, gatewayName: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Approval needed · \(gatewayName)"
        content.body = Self.clip(approval.command)
        content.sound = .default
        content.categoryIdentifier = Self.category(for: approval)
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            "gateway": gatewayId.uuidString,
            "session": approval.sessionKey ?? "",
            "approval": approval.id,
        ]
        return UNNotificationRequest(identifier: Self.approvalIdentifier(approval.id), content: content, trigger: nil)
    }

    /// Whether the chat is on screen: in the main window or a chat window of its own.
    func isShowing(_ target: Target) -> Bool {
        self.visible == target || self.windowVisible.contains(target)
    }

    /// In the background the push for the same event is on its way; posting too would double it.
    public func deferredToPush(_ gatewayId: UUID) -> Bool {
        !self.appIsActive && self.pushDelivers(gatewayId)
    }

    func notifyQuestion(_ prompt: QuestionPrompt, gateway: GatewayStore) {
        guard prompt.questions.first != nil else { return }
        let agent = gateway.agent(prompt.agentId ?? prompt.sessionKey.flatMap(SessionKey.agentId(from:)) ?? gateway.defaultAgentId)
        let chat = prompt.sessionKey.flatMap { gateway.sessions[$0]?.title }
        let target = Target(gatewayId: gateway.id, sessionKey: prompt.sessionKey ?? "")
        // The open chat already shows the card.
        if self.appIsActive, prompt.sessionKey != nil, self.isShowing(target) { return }
        guard self.enabled else { return }
        self.advanceRefreshCursor(gateway.id, questionId: prompt.id)
        guard let center, let request = Self.questionRequest(prompt, gatewayId: gateway.id, agent: agent, chatTitle: chat)
        else { return }
        center.add(request)
    }

    /// What the live app just notified about must not be notified again by the next background refresh.
    private func advanceRefreshCursor(_ gatewayId: UUID, activityMs: Double? = nil, approvalId: String? = nil, questionId: String? = nil) {
        Self.advanceRefreshCursor(
            gatewayId, activityMs: activityMs, approvalId: approvalId, questionId: questionId, appIsActive: self.appIsActive)
    }

    nonisolated static func advanceRefreshCursor(
        _ gatewayId: UUID, activityMs: Double? = nil, approvalId: String? = nil, questionId: String? = nil,
        appIsActive: Bool, defaults: UserDefaults = .standard)
    {
        guard !appIsActive, ClosedAppDelivery.current(defaults) == .backgroundRefresh else { return }
        BackgroundRefreshCursorStore(defaults: defaults).advance(
            gatewayId: gatewayId, activityMs: activityMs, approvalId: approvalId, questionId: questionId)
    }

    nonisolated static func questionRequest(
        _ prompt: QuestionPrompt, gatewayId: UUID, agent: AgentSummary, chatTitle: String?) -> UNNotificationRequest?
    {
        guard let first = prompt.questions.first else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "\(agent.emoji.map { "\($0) " } ?? "")\(agent.name) has a question" + (chatTitle.map { " · \($0)" } ?? "")
        content.body = Self.clip(first.question)
        content.sound = .default
        content.categoryIdentifier = replyCategory
        content.interruptionLevel = .timeSensitive
        if let key = prompt.sessionKey { content.threadIdentifier = "\(gatewayId.uuidString)|\(key)" }
        content.userInfo = ["gateway": gatewayId.uuidString, "session": prompt.sessionKey ?? ""]
        return UNNotificationRequest(identifier: "question:\(prompt.id)", content: content, trigger: nil)
    }

    nonisolated static func replyTitle(rowTitle: String, agent: AgentSummary) -> String {
        "\(agent.emoji.map { "\($0) " } ?? "")\(rowTitle) · \(agent.name)"
    }

    private func title(row: SessionRow, gateway: GatewayStore) -> String {
        Self.replyTitle(rowTitle: row.title, agent: gateway.agent(row.agentId))
    }

    nonisolated static func replyContent(id: String, title: String, body: String, target: Target) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = replyCategory
        content.threadIdentifier = "\(target.gatewayId.uuidString)|\(target.sessionKey)"
        content.userInfo = ["gateway": target.gatewayId.uuidString, "session": target.sessionKey]
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }

    /// Posts what a background refresh found. The app isn't running, so there is no visible chat,
    /// dedupe history or push to defer to; the requests' own identifiers dedupe against live ones.
    public func postBackground(_ requests: [UNNotificationRequest]) async {
        guard self.enabled, let center else { return }
        for request in requests { try? await center.add(request) }
    }

    private func post(id: String, title: String, body: String, target: Target, activityMs: Double) {
        guard self.enabled, !self.deferredToPush(target.gatewayId) else { return }
        self.advanceRefreshCursor(target.gatewayId, activityMs: activityMs)
        guard let center else { return }
        if self.appIsActive, self.isShowing(target) { return }
        let dedupeKey = id.hasPrefix("reply:") ? "\(target.sessionKey)|\(body.prefix(80))" : id
        guard !self.recent.contains(id), !self.recent.contains(dedupeKey) else { return }
        self.recent.append(contentsOf: [id, dedupeKey])
        if self.recent.count > 200 { self.recent.removeFirst(self.recent.count - 200) }

        center.add(Self.replyContent(id: id, title: title, body: body, target: target))
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

    nonisolated static func clip(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return flattened.count > 220 ? String(flattened.prefix(219)) + "…" : flattened
    }

    /// The gateway a notification belongs to: ours carry `gateway`; an undecrypted push only `pincer.g`.
    nonisolated static func gatewayId(_ info: [AnyHashable: Any]) -> UUID? {
        let raw = info["gateway"] as? String ?? (info["pincer"] as? [String: Any])?["g"] as? String
        return raw.flatMap(UUID.init(uuidString:))
    }

    // MARK: Responses

    /// What to do with a notification response.
    public enum ResponseAction: Equatable, Sendable {
        /// Send this decision to exactly this gateway.
        case resolve(gatewayId: UUID, approvalId: String, decision: String)
        case open(Target)
        case none
    }

    /// Decides what a response does. Only the three approval actions on an approval category, with
    /// the notification's own `gateway` and `approval` fields, resolve anything; an undecrypted push
    /// (only `pincer.g`) never does and opens that gateway instead. A plain tap opens the chat; a
    /// dismissal does nothing.
    public nonisolated static func interpret(
        actionIdentifier: String, categoryIdentifier: String, userInfo info: [AnyHashable: Any]) -> ResponseAction
    {
        if let decision = self.approvalDecision(for: actionIdentifier) {
            guard self.approvalCategories.contains(categoryIdentifier) else { return .none }
            guard let gateway = (info["gateway"] as? String).flatMap(UUID.init(uuidString:)) else {
                // Not decrypted: only `pincer.g`, no approval id. Open that gateway instead.
                return self.gatewayId(info).map { .open(Target(gatewayId: $0, sessionKey: "")) } ?? .none
            }
            guard let approval = info["approval"] as? String, !approval.isEmpty else { return .none }
            return .resolve(gatewayId: gateway, approvalId: approval, decision: decision)
        }
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let gateway = self.gatewayId(info),
              let session = info["session"] as? String, !session.isEmpty
        else { return .none }
        return .open(Target(gatewayId: gateway, sessionKey: session))
    }

    /// Answers an approval from a notification action: `(gateway, approval id, decision)`, awaited
    /// until the Gateway replies or the time budget runs out. Set by `AppModel`; if no model exists
    /// yet (a background launch), `AppModel.shared` is created, which sets it.
    public var approvalResolver: (@MainActor (UUID, String, String) async -> ApprovalOutcome)?
    /// Finds a saved gateway, for the follow-up's wording. Set by `AppModel`.
    public var gatewayLookup: (@MainActor (UUID) -> GatewayStore?)?
    /// Keeps the app running while an action resolves: called with a name and a handler to run if
    /// the system's time runs out (it cancels the resolve), returns the closure that ends it. The iOS
    /// app wraps `UIApplication.beginBackgroundTask`.
    public var beginBackgroundActivity: @MainActor (String, @escaping @MainActor () -> Void) -> (@MainActor () -> Void) = { _, _ in {} }

    func perform(_ action: ResponseAction, category: String, threadIdentifier: String, sessionKey: String?) async {
        switch action {
        case .none:
            return
        case let .open(target):
            if let onOpen = self.onOpen { onOpen(target) } else { self.pendingOpen = target }
        case let .resolve(gatewayId, approvalId, decision):
            if self.approvalResolver == nil { _ = AppModel.shared }
            guard let resolver = self.approvalResolver else { return }
            let resolve = Task { await resolver(gatewayId, approvalId, decision) }
            let end = self.beginBackgroundActivity("Answer approval") { resolve.cancel() }
            defer { end() }
            let outcome = await withTaskCancellationHandler { await resolve.value } onCancel: { resolve.cancel() }
            await self.postFollowUp(
                outcome, gatewayId: gatewayId, approvalId: approvalId, sessionKey: sessionKey,
                threadIdentifier: threadIdentifier, originalCategory: category)
        }
    }

    /// The notification that replaces an approval's after a failed or stale action. Same identifier
    /// (`approval:<id>`) and thread, not time-sensitive, and never the command text. Nil when there's
    /// nothing to say (success, or a duplicate action).
    public nonisolated static func followUpContent(
        for outcome: ApprovalOutcome, gatewayId: UUID, gatewayName: String?, context: String?,
        approvalId: String, sessionKey: String?, threadIdentifier: String?, originalCategory: String) -> UNMutableNotificationContent?
    {
        guard let body = outcome.followUpBody(gatewayName: gatewayName) else { return nil }
        let content = UNMutableNotificationContent()
        content.title = ["Approval", gatewayName, context].compactMap { $0 }.joined(separator: " · ")
        content.body = body
        content.sound = .default
        content.categoryIdentifier = outcome.followUpCategory(original: originalCategory)
        content.interruptionLevel = .active
        if let threadIdentifier, !threadIdentifier.isEmpty { content.threadIdentifier = threadIdentifier }
        content.userInfo = ["gateway": gatewayId.uuidString, "approval": approvalId, "session": sessionKey ?? ""]
        return content
    }

    private func postFollowUp(
        _ outcome: ApprovalOutcome, gatewayId: UUID, approvalId: String, sessionKey: String?,
        threadIdentifier: String, originalCategory: String) async
    {
        let store = self.gatewayLookup?(gatewayId)
        var context: String?
        if let store {
            let approval = store.approvals.first { $0.id == approvalId }
            let key = sessionKey.flatMap { $0.isEmpty ? nil : $0 } ?? approval?.sessionKey
            context = key.flatMap { store.sessions[$0]?.title }
                ?? (approval?.agentId ?? key.flatMap(SessionKey.agentId(from:))).map { store.agent($0).name }
        }
        guard let center,
              let content = Self.followUpContent(
                  for: outcome, gatewayId: gatewayId, gatewayName: store?.profile.name, context: context,
                  approvalId: approvalId, sessionKey: sessionKey, threadIdentifier: threadIdentifier,
                  originalCategory: originalCategory)
        else { return }
        // One notification per approval: a push for it has Apple's identifier, so drop it first.
        let identifier = Self.approvalIdentifier(approvalId)
        let others = await self.deliveredApprovalIdentifiers(gatewayId: gatewayId, id: approvalId).filter { $0 != identifier }
        center.removeDeliveredNotifications(withIdentifiers: others)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    nonisolated static func approvalIdentifier(_ id: String) -> String { "approval:\(id)" }

    /// Removes every delivered notification for this approval: the local `approval:<id>` and any
    /// push whose `userInfo.approval` matches on the same gateway.
    public func removeApproval(gatewayId: UUID, id: String) async {
        guard let center else { return }
        var ids = await self.deliveredApprovalIdentifiers(gatewayId: gatewayId, id: id)
        ids.append(Self.approvalIdentifier(id))
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func deliveredApprovalIdentifiers(gatewayId: UUID, id: String) async -> [String] {
        guard let center else { return [] }
        let delivered = await center.deliveredNotifications()
        return delivered.filter { notification in
            let info = notification.request.content.userInfo
            return notification.request.identifier == Self.approvalIdentifier(id)
                || (info["approval"] as? String == id && Self.gatewayId(info) == gatewayId)
        }.map(\.request.identifier)
    }

    // MARK: UNUserNotificationCenterDelegate

    // These use the completion-handler forms, not `async`: UIKit requires the handlers to be called
    // on the main thread and aborts otherwise (#330), but the `@objc` thunk of a `nonisolated async`
    // requirement calls them from the cooperative thread pool. Each handler runs on the main actor.

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        let info = notification.request.content.userInfo
        let gateway = notification.request.trigger is UNPushNotificationTrigger ? Self.gatewayId(info) : nil
        let complete = MainThreadCompletion(completionHandler)
        Task { @MainActor in
            // While connected, the live stream already notified (or chose not to, for the open chat).
            let redundant = gateway.map { self.isConnected($0) } ?? false
            complete(redundant ? [] : [.banner, .list, .sound])
        }
    }

    /// Awaits the approval's resolution before completing, so iOS keeps the app running until the
    /// Gateway has it.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void)
    {
        let content = response.notification.request.content
        let action = Self.interpret(
            actionIdentifier: response.actionIdentifier, categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo)
        let category = content.categoryIdentifier
        let thread = content.threadIdentifier
        let session = content.userInfo["session"] as? String
        let complete = MainThreadCompletion(completionHandler)
        Task { @MainActor in
            await self.perform(action, category: category, threadIdentifier: thread, sessionKey: session)
            complete(())
        }
    }
}

/// A system completion handler, only ever called from the main actor.
private struct MainThreadCompletion<Value>: @unchecked Sendable {
    private let handler: (Value) -> Void

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    @MainActor func callAsFunction(_ value: Value) {
        self.handler(value)
    }
}

/// Whether the system's notification permission prompt is up, so other first-launch UI can wait for it.
@MainActor
@Observable
public final class NotificationPrompt {
    public static let shared = NotificationPrompt()
    public internal(set) var isShowing = false

    public init() {}
}
