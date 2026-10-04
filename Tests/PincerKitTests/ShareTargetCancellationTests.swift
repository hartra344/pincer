#if DEBUG
import CryptoKit
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Share target cancellation", .timeLimit(.minutes(2)))
struct ShareTargetCancellationTests {
    @Test func canceledRefreshPreservesRememberedCurrentTarget() async throws {
        let suite = "share-cancel-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = GatewayProfile(name: "Fixture", url: "ws://fixture.invalid", authMode: .none)
        let transport = ShareTargetOwnershipTests.Transport("main", held: false)
        defaults.set("new:main", forKey: ShareModel.lastTargetKey(profile.id))
        let model = ShareModel(profiles: [profile], identity: DeviceIdentity(privateKey: .init()), defaults: defaults,
                               connectionFactory: { _, _ in transport.adapter() })
        model.connect()
        let pump = try #require(model.actualPumpTask)
        defer { transport.release(); model.disconnect() }
        var admittedTask: Task<Void, Never>?
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while model.phase != .ready { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
            #expect(model.target == .newChat(agentId: "main"))
            let calls = transport.calls, agents = model.agents, chats = model.chats
            let canceled = Task { await model.refreshTargets() }; canceled.cancel(); await canceled.value
            #expect(transport.calls == calls && model.agents == agents && model.chats == chats && model.target == .newChat(agentId: "main"))
            await model.refreshTargets()
            #expect(transport.calls == calls + 2 && model.target == .newChat(agentId: "main"))
            transport.open = false
            let admitted = Task { await model.refreshTargets() }
            admittedTask = admitted
            while transport.held.count != 2 { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
            admitted.cancel(); transport.release(); await admitted.value
            #expect(model.agents == agents && model.chats == chats && model.target == .newChat(agentId: "main"))
            model.disconnect(); await pump.value
        } catch {
            admittedTask?.cancel(); transport.release(); model.disconnect()
            await admittedTask?.value; await pump.value; throw error
        }
    }
}
#endif
