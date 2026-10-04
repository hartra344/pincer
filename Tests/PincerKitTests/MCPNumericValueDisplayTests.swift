import Foundation
import Testing
@testable import PincerKit

struct MCPNumericValueDisplayTests {
    @Test func ordinaryValuesAndRedactionKeepTheirDisplay() throws {
        let server = try #require(MCPServer(name: "display", json: Fixtures.json(#"{"command":"fixture","env":{"INTEGER":42,"FRACTION":1.25,"BOOL":true,"TEXT":"exact text","SECRET":"__OPENCLAW_REDACTED__"}}"#)))
        #expect(server.env.first { $0.key == "INTEGER" }?.value == "42")
        #expect(server.env.first { $0.key == "FRACTION" }?.value == "1.25")
        #expect(server.env.first { $0.key == "BOOL" }?.value == "true")
        #expect(server.env.first { $0.key == "TEXT" }?.value == "exact text")
        #expect(server.env.first { $0.key == "SECRET" }?.isRedacted == true)
    }

    @Test func oversizedNumericEnvironmentValueCannotCrashSettings() throws {
        // Defensive decoding of malformed config: env/header values should be strings.
        // Loading a config error must not kill the client before it can be corrected.
        let server = try #require(MCPServer(name: "display", json: Fixtures.json(#"{"command":"fixture","env":{"OVERSIZED":1e30}}"#)))
        let value = try #require(server.env.first { $0.key == "OVERSIZED" }?.value)
        #expect(value == String(1e30))
        #expect(server.raw["env"]?["OVERSIZED"]?.double == 1e30)
    }
}
