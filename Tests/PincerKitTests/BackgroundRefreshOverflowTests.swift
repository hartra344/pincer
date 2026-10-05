import Foundation
import Testing
@testable import PincerKit

@Suite("Background refresh overflow summary", .timeLimit(.minutes(2)))
struct BackgroundRefreshOverflowTests {
    private func rows(_ count: Int) -> [SessionRow] {
        (0..<count).map { index in
            SessionRow(.object(["key": .string("agent:main:dashboard:overflow-\(index)"),
                "unread": true, "lastActivityAt": .number(Double(2000 + index)), "hasActiveRun": false]))!
        }
    }
    @Test func cappedRepliesIncludeOneSummaryWithoutChangingIndividualCap() {
        let snapshot = BackgroundRefreshSnapshot(sessions: self.rows(11))
        let result = BackgroundRefreshPlanner.plan(snapshot: snapshot,
            cursor: .init(activityMs: 1000, approvalIds: [], questionIds: []), filter: .init(),
            gatewayId: UUID(), gatewayName: "Home")
        #expect(result.requests.count == 11)
        #expect(result.requests.filter { $0.identifier.hasPrefix("reply:") }.count == 10)
        #expect(result.cursor.activityMs == 2010)
        let repeated = BackgroundRefreshPlanner.plan(snapshot: snapshot, cursor: result.cursor,
            filter: .init(), gatewayId: UUID(), gatewayName: "Home")
        #expect(repeated.requests.isEmpty)
    }
    @Test func ordinaryCapBaselineAndEmptyRemainUnchanged() {
        let gateway = UUID()
        for count in [0, 1, 10] {
            let snapshot = BackgroundRefreshSnapshot(sessions: self.rows(count))
            let result = BackgroundRefreshPlanner.plan(snapshot: snapshot,
                cursor: .init(activityMs: 1000, approvalIds: [], questionIds: []), filter: .init(),
                gatewayId: gateway, gatewayName: "Home")
            #expect(result.requests.count == count)
            #expect(BackgroundRefreshPlanner.plan(snapshot: snapshot, cursor: nil, filter: .init(),
                gatewayId: gateway, gatewayName: "Home").requests.isEmpty)
        }
    }
}
