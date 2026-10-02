import Foundation
import Testing
@testable import PincerKit

@Suite("Demo agent and model settings")
struct DemoAgentModelsSettingsTests {
    @Test func demoConfigMakesAgentAndModelSettingsSectionsAvailable() async throws {
        let demo = DemoGateway()
        let config = ConfigSnapshot(response: try await demo.handle("config.get", [:])).config
        let schema = ConfigSchema(response: try await demo.handle("config.schema", [:]))

        // SettingsCatalog uses these exact schema/config field lists to decide whether its
        // Agents & Models page sections exist.
        let agentDefaults = schema.fields(at: ["agents", "defaults"],
                                          value: config.value(at: ["agents", "defaults"]))
        let models = schema.fields(at: ["models"], value: config["models"])
        #expect(!agentDefaults.isEmpty)
        #expect(!models.isEmpty)

        let primary = config.value(at: ["agents", "defaults", "model", "primary"])?.string
        #expect(primary == "anthropic/claude-opus-4-8")
        let catalog = try await demo.handle("models.list", [:])["models"]?.array ?? []
        #expect(catalog.contains { "\($0["provider"]?.string ?? "")/\($0["id"]?.string ?? "")" == primary })

        let agents = try await demo.handle("agents.list", [:])["agents"]?.array ?? []
        #expect(agents.contains { $0["id"]?.string == "main" && $0["name"]?.string == "Claw" })
    }
}
