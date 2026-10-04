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
        // Official McpServerSchema accepts strings, numbers and booleans for env/headers.
        // A finite number has no native Int ceiling and must remain displayable.
        let server = try #require(MCPServer(name: "display", json: Fixtures.json(#"{"command":"fixture","env":{"OVERSIZED":1e30}}"#)))
        let value = try #require(server.env.first { $0.key == "OVERSIZED" }?.value)
        #expect(value == String(1e30))
        #expect(server.raw["env"]?["OVERSIZED"]?.double == 1e30)
    }
    @Test func headerBoundariesAndMixedScalarValuesKeepTheirSource() throws {
        for number in [Double(Int.max).nextDown, Double(Int.max), Double(Int.min), 1e30, -1e30,
                       Double.nan, Double.infinity, -Double.infinity] {
            let raw: JSONValue = ["url": "https://fixture.invalid/mcp", "headers": ["VALUE": .number(number)]]
            let server = try #require(MCPServer(name: "headers", json: raw))
            let expected = Int(exactly: number).map { String($0) } ?? String(number)
            #expect(server.headers.first?.value == expected)
            #expect(server.raw["headers"]?["VALUE"]?.double?.isNaN == number.isNaN)
        }
        let raw: JSONValue = ["url": "https://fixture.invalid/mcp", "headers": ["INTEGER": -42, "BOOL": false, "SECRET": "__OPENCLAW_REDACTED__"]]
        let server = try #require(MCPServer(name: "headers", json: raw))
        #expect(server.headers.first { $0.key == "INTEGER" }?.value == "-42")
        #expect(server.headers.first { $0.key == "BOOL" }?.value == "false")
        #expect(server.headers.first { $0.key == "SECRET" }?.isRedacted == true)
        #expect(server.raw == raw)
    }
}
