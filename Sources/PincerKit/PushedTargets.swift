import Foundation
import PincerPush
import UserNotifications

/// What the relay's pushes already told the user about, so a silent-push refresh doesn't post
/// the same chat reply or approval a second time.
public struct PushedTargets: Sendable, Equatable {
    /// `"<GATEWAY-UUID>|<sessionKey>"`
    public var sessions: Set<String>
    /// `"<GATEWAY-UUID>|<approvalId>"`
    public var approvals: Set<String>
    /// `"<GATEWAY-UUID>|<questionId>"`
    public var questions: Set<String>

    public init(sessions: Set<String> = [], approvals: Set<String> = [], questions: Set<String> = []) {
        self.sessions = sessions
        self.approvals = approvals
        self.questions = questions
    }

    public init(userInfos: [[AnyHashable: Any]]) {
        var targets = PushedTargets()
        for info in userInfos {
            guard let gateway = (info["gateway"] as? String).flatMap(UUID.init(uuidString:))?.uuidString else { continue }
            if let approval = info["approval"] as? String, !approval.isEmpty {
                targets.approvals.insert("\(gateway)|\(approval)")
            }
            if let question = info["question"] as? String, !question.isEmpty {
                targets.questions.insert("\(gateway)|\(question)")
            }
            if let session = info["session"] as? String, !session.isEmpty {
                targets.sessions.insert("\(gateway)|\(session)")
            }
        }
        self = targets
    }

    public init(message: PushMessage) {
        let gateway = message.gatewayId.uuidString
        var targets = PushedTargets()
        switch message.kind {
        case let .approval(id, _): targets.approvals.insert("\(gateway)|\(id)")
        case let .question(id): targets.questions.insert("\(gateway)|\(id)")
        case .chat: if let key = message.sessionKey { targets.sessions.insert("\(gateway)|\(key)") }
        case .other: break
        }
        self = targets
    }

    public func union(_ other: PushedTargets) -> PushedTargets {
        PushedTargets(
            sessions: self.sessions.union(other.sessions), approvals: self.approvals.union(other.approvals),
            questions: self.questions.union(other.questions))
    }

    public func covers(_ request: UNNotificationRequest) -> Bool {
        let info = request.content.userInfo
        guard let gateway = (info["gateway"] as? String).flatMap(UUID.init(uuidString:))?.uuidString else { return false }
        if let approval = info["approval"] as? String, !approval.isEmpty {
            return self.approvals.contains("\(gateway)|\(approval)")
        }
        if request.identifier.hasPrefix("question:") {
            return self.questions.contains("\(gateway)|\(request.identifier.dropFirst("question:".count))")
        }
        guard let session = info["session"] as? String, !session.isEmpty else { return false }
        return self.sessions.contains("\(gateway)|\(session)")
    }
}

/// Targets of pushes that arrive while a silent-push refresh is already running. The run reads it
/// when it posts, so those pushes aren't repeated.
@MainActor
public final class PushedTargetsBox {
    public private(set) var targets: PushedTargets

    public init(_ targets: PushedTargets = PushedTargets()) { self.targets = targets }

    public func cover(_ more: PushedTargets) { self.targets = self.targets.union(more) }
}
