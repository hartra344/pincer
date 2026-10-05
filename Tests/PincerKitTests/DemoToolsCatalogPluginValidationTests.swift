import Testing
@testable import PincerKit

// Official eaae0fdae778ff2711600323bc5180b28666db27 tools-catalog.ts validates before handler work.
@Suite(.timeLimit(.minutes(2)))
struct DemoToolsCatalogPluginValidationTests {
    @Test(arguments: [JSONValue.string("false"), .number(0), .null])
    func invalidIncludePluginsUsesCanonicalBooleanError(value: JSONValue) async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("tools.catalog", [:])
        do {
            _ = try await demo.handle("tools.catalog", .object(["includePlugins": value]))
            Issue.record("Actual Demo catalog must reject non-Boolean includePlugins")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid tools.catalog params: at /includePlugins: must be boolean")
        }
        let after = try await demo.handle("tools.catalog", [:])
        #expect(after == before)
    }
    @Test func actualBooleanAndOmittedCatalogControls() async throws {
        let demo = DemoGateway()
        let all = try await demo.handle("tools.catalog", [:])
        let groups = try #require(all["groups"]?.array)
        let hasCore = groups.contains { $0["source"]?.text == "core" }
        let hasPlugin = groups.contains { $0["source"]?.text == "plugin" }
        #expect(!groups.isEmpty && hasCore && hasPlugin)
        let included = try await demo.handle("tools.catalog", ["includePlugins": true])
        #expect(included == all)
        let excluded = try await demo.handle("tools.catalog", ["includePlugins": false])
        let expected = groups.filter { $0["source"]?.text != "plugin" }
        #expect(excluded["groups"]?.array == expected)
    }
}
