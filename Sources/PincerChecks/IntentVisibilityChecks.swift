import Foundation
import PincerKit

/// #187: Shortcuts/widget unread lists honor each Gateway's sidebar choices.
@MainActor
func runIntentVisibilityChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
    let work = GatewayProfile(name: "Work", url: "ws://127.0.0.1:2", authMode: .none)
    let normal = "agent:main:main"
    let automation = "agent:main:cron:briefing"
    let slash = "agent:main:discord:slash:1"
    let rows = [normal, automation, slash].enumerated().map { index, key in
        SessionRow(.object(["key": .string(key), "unread": true,
                            "lastActivityAt": .number(Double(index + 1))]))!
    }
    let targets = GatewayTargets(agents: [], defaultAgentId: "main", sessions: rows)
    let service = IntentService(profiles: [home, work], hasIdentity: true, selectedGatewayId: nil,
                                connector: FakeIntentConnector(live: [home.id: targets, work.id: targets]),
                                labels: defaults)
    do {
        let hidden = try await service.unreadChats(gatewayId: home.id)
        check(hidden.map(\.sessionKey) == [normal], "unread choices: hidden kinds excluded by default")
        defaults.set(true, forKey: "pincer.showAutomations.\(home.id.uuidString)")
        defaults.set(true, forKey: "pincer.showSlashCommands.\(work.id.uuidString)")
        let combined = try await service.unreadChats(gatewayId: nil)
        check(combined.filter { $0.gatewayId == home.id }.map(\.sessionKey) == [automation, normal]
              && combined.filter { $0.gatewayId == work.id }.map(\.sessionKey) == [slash, normal],
              "unread choices: each Gateway uses its own current preferences")
        defaults.set(false, forKey: "pincer.showAutomations.\(home.id.uuidString)")
        defaults.set(automation, forKey: "pincer.selected.\(home.id.uuidString)")
        let selected = try await service.unreadChats(gatewayId: home.id)
        check(selected.map(\.sessionKey) == [automation, normal],
              "unread choices: the selected hidden-kind chat remains visible")
    } catch { check(false, "unread choices: \(error.localizedDescription)") }
}

/// Uses the existing unread Morning briefing demo seed and the app's actual live connector.
@MainActor
func runDemoIntentVisibilityChecks() async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        defaults.removePersistentDomain(forName: suite)
    }
    let gateway = app.add(.demo(), secret: nil)
    let ready = await waitFor("demo unread visibility") {
        gateway.state.isConnected && gateway.sessions["agent:main:cron:morning-briefing"] != nil
    }
    check(ready, "demo unread choices: connected with seeded briefing")
    guard ready else { return }
    let service = IntentService(profiles: [gateway.profile], hasIdentity: false, selectedGatewayId: gateway.id,
                                connector: GatewayIntentConnector(liveStore: { $0 == gateway.id ? gateway : nil }),
                                labels: defaults)
    do {
        gateway.showAutomations = false
        gateway.showSlashCommands = false
        let hidden = try await service.unreadChats(gatewayId: gateway.id)
        check(hidden.count == gateway.totalUnread && !hidden.contains { $0.sessionKey.contains(":cron:") },
              "demo unread choices: Shortcuts agrees with the hidden-automation badge")
        gateway.showAutomations = true
        let shown = try await service.unreadChats(gatewayId: gateway.id)
        check(shown.count == gateway.totalUnread
              && shown.contains { $0.sessionKey == "agent:main:cron:morning-briefing" },
              "demo unread choices: enabling automations immediately includes unread briefing")
        gateway.showAutomations = false
        let hiddenAgain = try await service.unreadChats(gatewayId: gateway.id)
        check(hiddenAgain.count == gateway.totalUnread && hiddenAgain.count == hidden.count,
              "demo unread choices: disabling automations updates the same service")
    } catch { check(false, "demo unread choices: \(error.localizedDescription)") }
}
