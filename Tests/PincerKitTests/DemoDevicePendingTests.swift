import Testing
@testable import PincerKit

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DemoDevicePendingTests {
    @Test func rejectRemovesPendingAndUnknownIdThrows() async throws {
        let demo = DemoGateway()
        let pending = try await demo.handle("device.pair.list", [:])["pending"]?.array ?? []
        let id = try #require(pending.first?["requestId"]?.text)
        let reply = try await demo.handle("device.pair.reject", ["requestId": .string(id)])
        #expect(reply["requestId"]?.text == id)
        let after = try await demo.handle("device.pair.list", [:])["pending"]?.array ?? []
        #expect(after.count == pending.count - 1)
        for method in ["device.pair.reject", "device.pair.approve"] {
            do {
                _ = try await demo.handle(method, ["requestId": .string(id)])
                Issue.record("\(method) of a resolved request must fail")
            } catch {
                guard case let GatewayError.rpc(_, message, _) = error else { Issue.record("\(error)"); continue }
                #expect(message == "unknown requestId")
            }
        }
    }
}
