import Foundation
import Testing
import UserNotifications
@testable import PincerKit

struct ActivityNotificationTimestampTests {
    private func plan(_ timestamp: Double) throws -> (requests: [UNNotificationRequest], cursor: BackgroundRefreshCursor) {
        // updatedAt is actual Gateway session metadata; unread is local notification state.
        let row = try #require(SessionRow(["key": "agent:main:dashboard:timestamp", "updatedAt": .number(timestamp), "unread": true]))
        return BackgroundRefreshPlanner.plan(snapshot: .init(sessions: [row]),
            cursor: .init(activityMs: 1000, approvalIds: [], questionIds: []), filter: .init(),
            gatewayId: UUID(), gatewayName: "Fixture", now: Date(timeIntervalSince1970: 1700000000))
    }

    @Test func ordinaryActivityKeepsItsNotificationIdentity() throws {
        let result = try plan(2000)
        #expect(result.requests.map(\.identifier) == ["reply:agent:main:dashboard:timestamp:2000"])
        #expect(result.cursor.activityMs == 2000)
    }

    @Test func oversizedActivityCannotCrashNotificationPlanning() throws {
        let result = try plan(1e30)
        let request = try #require(result.requests.first)
        #expect(request.identifier == "reply:agent:main:dashboard:timestamp:\(String(1e30))")
        #expect(result.requests.count == 1 && result.cursor.activityMs == 1e30)
        #expect(try plan(1e30).requests.first?.identifier == request.identifier)
    }
    @Test func sharedIdentityPreservesBoundariesAndTruncation() {
        for value in [Double(Int.max).nextDown, Double(Int.max), Double(Int.min), 1e30,
                      Double.infinity, -Double.infinity, Double.nan] {
            #expect(ActivityNotificationIdentity.make(key: "k", activityMs: value)
                    == ActivityNotificationIdentity.make(key: "k", activityMs: value))
        }
        #expect(ActivityNotificationIdentity.make(key: "k", activityMs: 123.9) == "reply:k:123")
        #expect(ActivityNotificationIdentity.make(key: "k", activityMs: -123.9) == "reply:k:-123")
    }
}
