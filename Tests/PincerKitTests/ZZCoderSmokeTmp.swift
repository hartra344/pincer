import Foundation
import Testing
@testable import PincerKit

@MainActor @Test func zzCoderDemoDeviceSmoke() async throws {
    Keychain.useInMemoryStore()
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    for _ in 0..<100 where !gateway.state.isConnected { try await Task.sleep(for: .milliseconds(50)) }
    #expect(gateway.state.isConnected)
    let m = gateway.devices
    #expect(m.canView && m.canManage && m.supported)
    await m.load()
    let p0 = m.pending.count, d0 = m.paired.count
    #expect(p0 >= 1)
    #expect(m.paired.first.map(m.isSelf) == true)
    #expect(m.pendingCount == p0)
    let req = try #require(m.pending.first { $0.requestId == DemoGateway.demoPendingRequestId })
    #expect(await m.approve(req))
    #expect(m.pending.count == p0 - 1 && m.paired.count == d0 + 1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(m.pending.count == p0 - 1 && m.paired.count == d0 + 1)
    let other = try #require(m.paired.first { $0.deviceId == DemoGateway.demoIPadDeviceId })
    #expect(await m.rename(other, to: "Kitchen iPad"))
    print("ZZDBG", m.paired.map { "\($0.deviceId.prefix(6)) \($0.title) \($0.operatorLabel ?? "-")" }, other.deviceId.prefix(6))
    #expect(m.paired.first { $0.deviceId == other.deviceId }?.title == "Kitchen iPad")
    #expect(await m.remove(other))
    #expect(m.paired.count == d0)
    if let r = m.pending.first { #expect(await m.reject(r)); #expect(m.pending.count == p0 - 2) }
    await m.loadNodes()
    #expect(m.nodesLoaded && m.nodesLoadState == .idle && !m.nodes.isEmpty)
    if let n = m.nodes.first {
        #expect(await m.renameNode(n, to: "Renamed"))
        #expect(m.nodes.contains { $0.title == "Renamed" })
        #expect(await m.removeNode(n))
        #expect(!m.nodes.contains { $0.nodeId == n.nodeId })
    }
    gateway.stop()
}
