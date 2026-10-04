#if DEBUG
import CryptoKit
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Share target connection ownership", .timeLimit(.minutes(2)))
struct ShareTargetOwnershipTests {
    @MainActor final class Transport {
        let agent: String
        var state: ShareConnection.StateHandler?
        var entered = false, open = false
        var held: [CheckedContinuation<Void, Never>] = []
        var calls = 0
        var fail = false
        init(_ agent: String, held: Bool) { self.agent = agent; open = !held }
        func adapter() -> ShareConnection {
            ShareConnection(request: { method, params, timeout in
                self.calls += 1
                #expect((method == "agents.list" && params == [:] && timeout == 20)
                        || (method == "sessions.list" && params == ["limit": 200, "includeLastMessage": false, "archived": false] && timeout == 30))
                if self.fail { throw GatewayError.rpc(code: "UNAVAILABLE", message: "target read unavailable", details: nil) }
                // Intentionally held already-computed delivery survives pump cancellation;
                // the fixture explicitly releases and awaits actual pump completion.
                if !self.open { self.entered = true; await withCheckedContinuation { self.held.append($0) } }
                return method == "agents.list" ? ["agents": [["id": .string(self.agent), "name": .string(self.agent)]], "defaultId": .string(self.agent)]
                    : ["sessions": [["key": .string("agent:\(self.agent):main"), "agentId": .string(self.agent), "kind": "direct", "updatedAt": 1700000000000]]]
            }, setHandlers: { _, state in self.state = state }, start: {
                self.state?(.connected, GatewayHello(payload: ["server": ["version": "fixture"], "auth": ["scopes": ["operator.read"]], "policy": ["maxPayload": 1048576, "tickIntervalMs": 30000]]))
            }, stop: {})
        }
        func release() { open = true; let values = held; held = []; for value in values { value.resume() } }
    }
    @Test(arguments: [false, true])
    func oldTargetLoadCannotPublishAfterSwitchOrDisconnect(disconnect: Bool) async throws {
        let suite = "share-owner-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = GatewayProfile(name: "A", url: "ws://a.invalid", authMode: .none)
        let b = GatewayProfile(name: "B", url: "ws://b.invalid", authMode: .none)
        let old = Transport("old", held: true), fresh = Transport("new", held: false)
        let model = ShareModel(profiles: [a,b], identity: DeviceIdentity(privateKey: .init()), defaults: defaults,
                               connectionFactory: { profile, _ in profile.id == a.id ? old.adapter() : fresh.adapter() })
        model.connect()
        let oldTask = try #require(model.actualPumpTask)
        defer { old.release(); fresh.release(); model.disconnect() }
        do {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !old.entered || old.calls != 2 { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        if disconnect { model.disconnect() }
        else {
            model.profileId = b.id
            while model.phase != .ready { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
            try #require(model.agents.map(\.id) == ["new"])
            try #require(model.chats.map(\.key) == ["agent:new:main"] && model.target == .chat("agent:new:main"))
        }
        let expectedAgents = model.agents, expectedChats = model.chats, expectedTarget = model.target, expectedPhase = model.phase
        old.release(); await oldTask.value
        #expect(model.agents == expectedAgents && model.chats == expectedChats && model.target == expectedTarget && model.phase == expectedPhase)
        if !disconnect {
            #expect(model.profileId == b.id && defaults.string(forKey: ShareModel.lastGatewayKey) == b.id.uuidString)
            #expect(model.target == .chat("agent:new:main"))
        }
        } catch {
            let currentTask = model.actualPumpTask
            old.release(); fresh.release(); model.disconnect(); await oldTask.value
            await currentTask?.value
            throw error
        }
    }
    @Test func ordinaryAndCurrentReadErrorsKeepExistingSemantics() async throws {
        let suite = "share-control-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = Transport("main", held: false)
        let model = ShareModel(profiles: [.demo()], identity: DeviceIdentity(privateKey: .init()), defaults: defaults,
                               connectionFactory: { _, _ in transport.adapter() })
        defer { model.disconnect() }
        model.connect()
        let pump = try #require(model.actualPumpTask)
        do {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while model.phase != .ready { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        #expect(model.agents.map(\.id) == ["main"] && model.target == .chat("agent:main:main"))
        transport.fail = true
        await model.refreshTargets()
        #expect(model.chats.isEmpty && model.agents.map(\.id) == ["main"] && model.target == .newChat(agentId: "main"))
        model.disconnect(); await pump.value
        } catch { transport.release(); model.disconnect(); await pump.value; throw error }
    }

}
#endif
