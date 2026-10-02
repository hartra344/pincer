import Foundation
#if DEBUG
@testable import PincerKit

@MainActor
func runDemoAgentModelsSchemaChecks() async {
    do {
        let demo = DemoGateway()
        let config = ConfigSnapshot(response: try await demo.handle("config.get", [:])).config
        let schema = ConfigSchema(response: try await demo.handle("config.schema", [:]))
        check(!schema.fields(at: ["agents", "defaults"], value: config.value(at: ["agents", "defaults"])).isEmpty
              && !schema.fields(at: ["models"], value: config["models"]).isEmpty,
              "demo settings schema exposes the existing Agents & Models page sections")
        let primary = config.value(at: ["agents", "defaults", "model", "primary"])?.string
        let models = try await demo.handle("models.list", [:])["models"]?.array ?? []
        check(primary != nil && models.contains { "\($0["provider"]?.string ?? "")/\($0["id"]?.string ?? "")" == primary },
              "demo default model is an actual seeded model catalog entry")
        check(config["models"]?["mode"]?.string == "merge"
              && config["mcp"]?["servers"]?.object?.isEmpty == false
              && config["channels"] != nil,
              "demo model settings preserve the existing MCP and channel configuration")
    } catch {
        check(false, "demo agent/model settings schema responds: \(error)")
    }
}

@MainActor
func runDemoAgentModelsPageChecks() async {
    let suite = "PincerChecks.demoAgentModels.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let ready = await waitFor("demo agent settings") {
        gateway.state.isConnected && gateway.agents.contains { $0.id == "main" }
    }
    check(ready, "demo agent settings connect with the seeded main agent")
    guard ready else { return }
    await gateway.settings.load()
    check(!gateway.settings.fields(at: ["agents", "defaults"]).isEmpty
          && !gateway.settings.fields(at: ["models"]).isEmpty,
          "the actual demo settings store has the fields used by the curated page guard")
    guard let agent = gateway.agents.first(where: { $0.id == "main" }) else { return }
    do {
        let identity = try await gateway.agentManagement.identity(agentId: agent.id)
        check(identity.name == agent.name && identity.emoji == agent.emoji,
              "the agent page receives the named demo agent's identity")
        // Keep the event pump alive until the actor's idle state reaches the store.
        await gateway.connection.stop()
        let stopped = await waitFor("demo agent settings disconnect") { gateway.state == .idle }
        check(stopped, "the demo Pet check disconnects before its local preference choices")
        guard stopped else { return }
        gateway.stop()
        defer { gateway.queuedAvatarChoices = [:] }
        let seed = gateway.avatarSeed(for: agent)
        let original = gateway.avatarCreature(for: agent.id)
        guard let choice = AvatarCreature.allCases.first(where: { $0 != original }) else { return }
        gateway.setAvatarCreature(choice, for: agent.id)
        check(gateway.avatarCreature(for: agent.id) == choice && gateway.avatarSeed(for: agent) == seed,
              "choosing a demo Pet character updates immediately without changing its identity seed")
        gateway.setAvatarCreature(original, for: agent.id)
        check(gateway.avatarCreature(for: agent.id) == original,
              "restoring the demo Pet choice returns the local picker to its previous value")
    } catch {
        check(false, "demo agent identity loads: \(error)")
    }
}
#else
import PincerKit
@MainActor func runDemoAgentModelsSchemaChecks() async {}
@MainActor func runDemoAgentModelsPageChecks() async {}
#endif
