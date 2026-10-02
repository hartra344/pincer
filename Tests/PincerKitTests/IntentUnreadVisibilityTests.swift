import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Intent unread visibility")
struct IntentUnreadVisibilityTests {
    @MainActor
    final class Connection: IntentConnection {
        let rows: [SessionRow]

        init(rows: [SessionRow]) { self.rows = rows }

        func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
            switch method {
            case "agents.list": return Fixtures.json(#"{"defaultId":"main","agents":[{"id":"main","identity":{"name":"Claw"}}]}"#)
            case "sessions.list": return .object(["sessions": .array(self.rows.map(\.raw))])
            default: return Fixtures.json("{}")
            }
        }

        func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int { 0 }
        func stopObserving(_ token: Int) {}
        func close() async {}
    }

    @MainActor
    struct Connector: IntentConnector {
        let connections: [UUID: Connection]

        func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection {
            self.connections[profile.id]!
        }

        func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { nil }
        func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { nil }
    }

    static func defaults() -> (UserDefaults, String) {
        let suite = "pincer.tests.intent-unread.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    static func rows() -> [SessionRow] {
        let values: [(key: String, activity: Double, unread: Bool, archived: Bool)] = [
            ("agent:main:main", 1, true, false),
            ("agent:main:cron:briefing", 3, true, false),
            ("agent:main:discord:slash:1", 2, true, false),
            ("agent:main:subagent:helper", 4, true, false),
            ("agent:main:cron:archived", 5, true, true),
            ("agent:main:discord:slash:read", 6, false, false),
        ]
        return values.map { item in
            return SessionRow(.object([
                "key": .string(item.key), "unread": .bool(item.unread), "archived": .bool(item.archived),
                "lastActivityAt": .number(item.activity),
            ]))!
        }
    }

    @Test func unreadListsUseEachGatewaySidebarPreferences() async throws {
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = GatewayProfile(name: "Home", url: "wss://home.example", authMode: .token)
        let work = GatewayProfile(name: "Work", url: "wss://work.example", authMode: .token)
        let rows = Self.rows()
        let connector = Connector(connections: [home.id: Connection(rows: rows), work.id: Connection(rows: rows)])
        defaults.set(true, forKey: "pincer.showAutomations.\(home.id.uuidString)")
        defaults.set(true, forKey: "pincer.showSlashCommands.\(work.id.uuidString)")
        let service = IntentService(profiles: [home, work], hasIdentity: true, selectedGatewayId: home.id,
                                    connector: connector, labels: defaults)

        let unread = try await service.unreadChats(gatewayId: nil)
        #expect(unread.filter { $0.gatewayId == home.id }.map(\.sessionKey)
                == ["agent:main:cron:briefing", "agent:main:main"],
                "Home shows only its enabled automation; hidden slash, archived, helper and read chats stay excluded")
        #expect(unread.filter { $0.gatewayId == work.id }.map(\.sessionKey)
                == ["agent:main:discord:slash:1", "agent:main:main"],
                "Work shows only its enabled slash chat; Home's toggle must not leak across gateways")
    }
}
