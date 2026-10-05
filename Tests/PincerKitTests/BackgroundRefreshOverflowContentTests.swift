import Foundation
import Testing
import UserNotifications
@testable import PincerKit

@Suite("Background summary content")
struct BackgroundRefreshOverflowContentTests {
    @Test func summaryIsAccurateSilentAndHasNoFalseChatDestination() throws {
        let gateway = UUID()
        let rows = (1...13).map { BackgroundRefreshTests.row(BackgroundRefreshTests.key($0), activity: Double(2000 + $0)) }
        let snapshot = BackgroundRefreshTests.snapshot(rows, approvals: [BackgroundRefreshTests.approval("a")],
            questions: [BackgroundRefreshTests.question("q")])
        let plan = BackgroundRefreshTests.plan(snapshot, cursor: BackgroundRefreshTests.base, gatewayId: gateway)
        let summaries = plan.requests.filter { $0.identifier.hasPrefix("refresh-summary:") }
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(plan.requests.count == 13) // approval + question + ten replies + one summary
        #expect(summary.content.title == "Home")
        #expect(summary.content.body == "And 3 more chats")
        #expect(summary.content.sound == nil)
        #expect(summary.content.userInfo["gateway"] as? String == gateway.uuidString)
        #expect(summary.content.userInfo["session"] == nil)
        #expect(summary.content.categoryIdentifier.isEmpty)
        #expect(Notifier.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: summary.content.categoryIdentifier, userInfo: summary.content.userInfo) == .none)
        #expect(BackgroundRefresh.quieted(plan.requests, firstMaySound: true).filter { $0.content.sound != nil }.count == 1)
        let duplicate = BackgroundRefreshTests.plan(snapshot, cursor: BackgroundRefreshTests.base, gatewayId: gateway)
        #expect(duplicate.requests.last?.identifier == summary.identifier)
        let otherGateway = BackgroundRefreshTests.plan(snapshot, cursor: BackgroundRefreshTests.base, gatewayId: UUID())
        #expect(otherGateway.requests.last?.identifier != summary.identifier)
    }
    @Test(arguments: [1, 2]) func summaryUsesExactSingularAndPlural(overflow: Int) throws {
        let rows = (1...(10 + overflow)).map { BackgroundRefreshTests.row(BackgroundRefreshTests.key($0), activity: Double(2000 + $0)) }
        let plan = BackgroundRefreshTests.plan(BackgroundRefreshTests.snapshot(rows), cursor: BackgroundRefreshTests.base)
        let summaries = plan.requests.filter { $0.identifier.hasPrefix("refresh-summary:") }
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.content.body == (overflow == 1 ? "And 1 more chat" : "And 2 more chats"))
        #expect(plan.requests.filter { $0.identifier.hasPrefix("reply:") }.count == 10)
    }
    @Test func excludedRowsDoNotIncreaseTheOverflow() {
        var rows = (1...10).map { BackgroundRefreshTests.row(BackgroundRefreshTests.key($0), activity: Double(2000 + $0)) }
        rows += [BackgroundRefreshTests.row("agent:main:dashboard:read", activity: 3000, unread: false),
                 BackgroundRefreshTests.row("agent:main:dashboard:active", activity: 3001, extra: "\"hasActiveRun\":true"),
                 BackgroundRefreshTests.row("agent:main:dashboard:archived", activity: 3002, extra: "\"archived\":true")]
        let plan = BackgroundRefreshTests.plan(BackgroundRefreshTests.snapshot(rows), cursor: BackgroundRefreshTests.base)
        #expect(plan.requests.count == 10)
        #expect(plan.requests.allSatisfy { $0.identifier.hasPrefix("reply:") })
    }
}
