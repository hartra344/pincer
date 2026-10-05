import Foundation
import UserNotifications
@testable import PincerKit

@MainActor func runBackgroundRefreshOverflowContentChecks() {
    let gateway = UUID()
    let rows = (0..<13).map { index in SessionRow(.object([
        "key": .string("agent:main:dashboard:summary-\(index)"), "unread": true,
        "lastActivityAt": .number(Double(2000 + index))]))! }
    let snapshot = BackgroundRefreshSnapshot(sessions: rows)
    let plan = BackgroundRefreshPlanner.plan(snapshot: snapshot,
        cursor: .init(activityMs: 0, approvalIds: [], questionIds: []), filter: .init(), gatewayId: gateway, gatewayName: "Home")
    let summaries = plan.requests.filter { $0.identifier.hasPrefix("refresh-summary:") }
    for overflow in [1, 2] {
        let sample = BackgroundRefreshSnapshot(sessions: Array(rows.prefix(10 + overflow)))
        let result = BackgroundRefreshPlanner.plan(snapshot: sample,
            cursor: .init(activityMs: 0, approvalIds: [], questionIds: []), filter: .init(), gatewayId: gateway, gatewayName: "Home")
        let summary = result.requests.filter { $0.identifier.hasPrefix("refresh-summary:") }
        check(summary.count == 1 && summary.first?.content.body == (overflow == 1 ? "And 1 more chat" : "And 2 more chats"),
              "summary uses exact singular and plural count")
    }
    check(summaries.count == 1, "one summary covers overflow"); guard let summary = summaries.first else { return }
    check(summary.content.body == "And 3 more chats" && summary.content.title == "Home", "summary accurately names three remaining chats and gateway")
    check(summary.content.sound == nil && summary.content.categoryIdentifier.isEmpty, "summary is silent without reply actions")
    check(summary.content.userInfo["gateway"] as? String == gateway.uuidString && summary.content.userInfo["session"] == nil,
          "aggregate carries gateway metadata without a false single-chat route")
    check(Notifier.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: "",
        userInfo: summary.content.userInfo) == .none, "aggregate tap does not falsely select a chat")
    check(BackgroundRefresh.quieted(plan.requests, firstMaySound: true).filter { $0.content.sound != nil }.count == 1,
          "actual runner quieting retains one sound")
}
