import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Runs menu availability")
struct RunsAvailabilityTests {
    @Test func completedHelpersKeepTheMenuAvailableUntilTheirRowsAreRemoved() {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop(); scratch.remove() }

        let root = "agent:main:dashboard:release"
        let otherRoot = "agent:main:dashboard:empty"
        let child = "agent:main:subagent:done"
        gateway.setSession(SessionRow(Fixtures.json(#"{"key":"\#(root)"}"#)), for: root)
        gateway.setSession(SessionRow(Fixtures.json(#"{"key":"\#(otherRoot)"}"#)), for: otherRoot)
        gateway.setSession(SessionRow(Fixtures.json(#"{"key":"\#(child)","spawnedBy":"\#(root)","status":"done"}"#)), for: child)

        #expect(gateway.hasRuns(sessionKey: root))
        #expect(!gateway.hasRuns(sessionKey: otherRoot), "another root's helpers must not expose its Runs item")

        gateway.setSession(nil, for: child)
        #expect(!gateway.hasRuns(sessionKey: root), "removing the completed helper row clears tree-only availability")
    }

    @Test func capturedTimelineKeepsRunsAvailableUntilTheBoundedHistoryEvictsIt() {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop(); scratch.remove() }

        let root = "agent:main:dashboard:captured"
        let otherRoot = "agent:main:dashboard:other"
        gateway.runTimelineState = RunTimeline(maxRuns: 1)
        let now = Date()
        func event(_ runID: String, _ sessionKey: String, _ seq: Int, _ phase: String) -> JSONValue {
            .object(["runId": .string(runID), "seq": .number(Double(seq)), "stream": .string("lifecycle"),
                     "sessionKey": .string(sessionKey), "data": .object(["phase": .string(phase)])])
        }

        gateway.runTimelineState.apply(agent: event("run-captured", root, 1, "start"), receivedAt: now)
        gateway.runTimelineState.apply(agent: event("run-captured", root, 2, "end"), receivedAt: now)
        #expect(gateway.hasRuns(sessionKey: root), "captured activity remains available even without helper rows")
        #expect(!gateway.hasRuns(sessionKey: otherRoot))

        gateway.runTimelineState.apply(agent: event("run-newer", otherRoot, 1, "start"), receivedAt: now)
        #expect(!gateway.hasRuns(sessionKey: root), "evicted run history no longer keeps a stale menu item")
        #expect(gateway.hasRuns(sessionKey: otherRoot))
    }
}
