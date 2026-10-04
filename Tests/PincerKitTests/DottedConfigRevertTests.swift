import Testing
@testable import PincerKit

@MainActor
@Suite("Config revert respects literal dotted server names")
struct DottedConfigRevertTests {
    private func fixture() async -> (GatewaySettingsModel, MCPServersModel) {
        let config: JSONValue = ["mcp": ["servers": [
            "acme": ["command": "acme", "connectionTimeoutMs": 15000],
            "acme.docs": ["command": "docs", "connectionTimeoutMs": 15000],
            "other": ["command": "other", "connectionTimeoutMs": 15000],
        ]]]
        let settings = GatewaySettingsModel(request: { method, _, _ in
            #expect(method == "config.get")
            return ["resolved": config, "hash": "fixture", "valid": true]
        }, scopes: { [GatewayConnection.adminScope] })
        await settings.reloadConfig()
        let servers = MCPServersModel(settings: settings, request: { _, _ in
            Issue.record("Remove and Undo are local draft actions and must not emit an RPC")
            return [:]
        })
        return (settings, servers)
    }

    private func timeoutField(_ name: String) throws -> ConfigField {
        // These are the existing MCP config fields. The schema only supplies the
        // real form's integer parser; no new Gateway method or property is introduced.
        let schema = ConfigSchema(schema: ["type": "object", "properties": ["mcp": [
            "type": "object", "properties": ["servers": ["type": "object", "properties": .object([
                name: ["type": "object", "properties": ["connectionTimeoutMs": ["type": "integer"]]],
            ])]],
        ]]])
        return try #require(schema.field(at: MCPServers.path + [name, "connectionTimeoutMs"], value: 15000))
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["acme.docs", "other"])
    func undoRemovalPreservesUnrelatedInvalidInput(_ sibling: String) async throws {
        let (settings, servers) = await self.fixture()
        let field = try self.timeoutField(sibling)
        settings.setText("not-a-number", for: field)
        let originalError = try #require(settings.inputError(for: field))
        try #require(settings.text(for: field) == "not-a-number" && settings.saveBlocker != nil)
        servers.remove("acme")
        try #require(servers.isRemoved("acme"))
        servers.undoRemove("acme")
        #expect(!servers.isRemoved("acme") && servers.server("acme") != nil)
        #expect(settings.text(for: field) == "not-a-number", "Undoing acme must not erase the distinct server's typed text")
        #expect(settings.inputError(for: field) == originalError, "The distinct server's invalid input still needs correction")
        #expect(settings.saveBlocker != nil, "Undo must not silently make invalid sibling input saveable")
    }

    @Test(.timeLimit(.minutes(2)))
    func undoRemovalClearsTheRemovedServersOwnDescendantInput() async throws {
        let (settings, servers) = await self.fixture()
        let field = try self.timeoutField("acme")
        settings.setText("not-a-number", for: field)
        try #require(settings.inputError(for: field) != nil)
        servers.remove("acme")
        try #require(servers.isRemoved("acme"))
        servers.undoRemove("acme")
        #expect(settings.text(for: field) == "15000")
        #expect(settings.inputError(for: field) == nil)
        #expect(settings.saveBlocker == nil && !settings.hasChanges)
    }
    @Test
    func structuralBuffersDistinguishIdenticalDisplayPathsAndSurviveAcknowledgment() {
        let literal = ["a.b"]
        let nested = ["a", "b"]
        var edits = ConfigEdits(base: ["a.b": 1, "a": ["b": 2]])
        edits.texts[literal] = "literal invalid"
        edits.texts[nested] = "nested invalid"
        edits.inputErrors[literal] = "literal error"
        edits.inputErrors[nested] = "nested error"
        #expect(ConfigPath.string(literal) == ConfigPath.string(nested))
        let acknowledged = ConfigEdits.acknowledging(intent: .init(), latest: edits, base: edits.base)
        #expect(acknowledged.texts == edits.texts && acknowledged.inputErrors == edits.inputErrors)
        edits.revert(nested)
        #expect(edits.texts[literal] == "literal invalid" && edits.inputErrors[literal] == "literal error")
        #expect(edits.texts[nested] == nil && edits.inputErrors[nested] == nil)
        edits.revert([])
        #expect(edits.texts.isEmpty && edits.inputErrors.isEmpty)
        edits.texts[literal] = "again"
        edits.inputErrors[literal] = "again"
        edits.discardAll()
        #expect(edits.texts.isEmpty && edits.inputErrors.isEmpty && !edits.hasChanges)
    }

}
