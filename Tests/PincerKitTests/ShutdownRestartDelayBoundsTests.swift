import Foundation
import Testing
@testable import PincerKit

@Suite("Shutdown restart delay bounds")
struct ShutdownRestartDelayBoundsTests {
    @Test func representableBoundaryAndPositiveOverflowStaySafe() {
        let near = Double(Int.max).nextDown
        #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": .number(near)]) == Int(exactly: near))
        for value in [Double(Int.max), Double.greatestFiniteMagnitude] {
            #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": .number(value)]) == Int.max)
        }
    }

    @Test func ordinaryAndTerminalDelaysKeepExistingMeaning() {
        #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": 0]) == 0)
        #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": 1500]) == 1500)
        #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": 1.6]) == 2)
        for value in [-1.0, Double.nan, .infinity, -.infinity] {
            #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": .number(value)]) == nil)
        }
        #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["reason": "stop"]) == nil)
    }

    @Test func oversizedOfficialIntegerRemainsANonterminalRestart() throws {
        // Official ShutdownEventSchema permits nonnegative integers without a maximum.
        let delay = try #require(GatewayHealthModel.restartExpectedMs(shutdown:
            ["reason": "restart", "restartExpectedMs": .number(1e30)]))
        #expect(delay >= 10_000, "Existing restart timer clamps large delays to ten seconds")
    }
}
