import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ModelRequestTests {
    @Test @MainActor func requestRoutesThroughTheConnection() async {
        let request = GatewayConnection(profile: .demo()).modelRequest(timeout: 5)
        do {
            _ = try await request("device.pair.list", [:])
            Issue.record("An unconnected request must throw")
        } catch {
            #expect(error.localizedDescription == GatewayError.notConnected.localizedDescription)
        }
    }
}
