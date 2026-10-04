import Foundation
import PincerKit

@MainActor func runShutdownRestartDelayBoundsChecks() {
    check(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": 1500]) == 1500,
          "ordinary shutdown restart delay remains unchanged")
    check(GatewayHealthModel.restartExpectedMs(shutdown: ["reason": "stop"]) == nil,
          "missing delay remains a terminal stop")
    let model = GatewayHealthModel { _, _ in .null }
    model.handle(event: "shutdown", payload: ["reason": "restart", "restartExpectedMs": .number(1e30)])
    check(model.restartState == .restarting && model.indicator == .restarting,
          "official unbounded integer delay reaches actual restart state without trapping")
    model.connectionChanged(.connected, hello: nil)
}
