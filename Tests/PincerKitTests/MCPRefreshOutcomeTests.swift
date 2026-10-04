import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("MCP queued refresh outcomes")
struct MCPRefreshOutcomeTests {
    @MainActor private final class Requests {
        var entered = 0
        var active = 0
        var maximumActive = 0
        var released: Set<Int> = []
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        let failures: Set<Int>
        let session: Bool
        init(failures: Set<Int>, session: Bool = false) { self.failures = failures; self.session = session }
        func release(_ index: Int) {
            released.insert(index)
            waiters.removeValue(forKey: index)?.resume()
        }
        func releaseAll() {
            for index in 1...max(entered, 2) { release(index) }
        }
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            #expect(method == (session ? ToolsPolicy.effectiveMethod : MCPServers.statusMethod))
            #expect(params == (session ? ["sessionKey": "agent:main:main", "agentId": "main"] : .object([:])))
            entered += 1
            let index = entered
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released.contains(index) || Task.isCancelled { continuation.resume() }
                    else { waiters[index] = continuation }
                }
            } onCancel: { Task { @MainActor in self.release(index) } }
            try Task.checkCancellation()
            if failures.contains(index) { throw GatewayError.closed("status round \(index) failed") }
            if session {
                return ["groups": [["id": "mcp", "label": "MCP", "source": "mcp", "tools": [
                    ["id": .string("round-\(index)__lookup"), "source": "mcp", "mcpServer": .string("round-\(index)"), "mcpToolName": "lookup"]]]]]
            }
            // Existing client contract only: upstream mcp.status support is still pending #327.
            return ["servers": [["name": .string("round-\(index)"), "state": "connected", "tools": ["lookup"]]]]
        }
    }

    private func model(_ requests: Requests) -> MCPServersModel {
        let settings = GatewaySettingsModel(request: { _, _, _ in [:] }, scopes: { [] })
        return MCPServersModel(settings: settings, methods: { [requests.session ? ToolsPolicy.effectiveMethod : MCPServers.statusMethod] },
                               sessionKey: { "agent:main:main" },
                               request: { try await requests.request($0, $1) })
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true], [true, false])
    func queuedRoundOwnsRunningAndFinalOutcome(_ latestFails: Bool, _ session: Bool) async throws {
        let requests = Requests(failures: latestFails ? [1, 2] : [1], session: session)
        let model = model(requests)
        var completed: Set<Int> = []
        var admittedCallers: Set<Int> = []
        let first = Task { await model.load(); completed.insert(1) }
        defer { requests.releaseAll(); first.cancel() }
        try #require(await eventually { requests.entered == 1 })
        #expect(model.loadState.isRunning && requests.active == 1)
        // These task bodies contain no suspension between the admission marker and
        // actual load(). Observing the marker therefore occurs after load has queued
        // its refresh and suspended on the existing load task.
        let second = Task { admittedCallers.insert(2); await model.load(); completed.insert(2) }
        let third = Task { admittedCallers.insert(3); await model.load(); completed.insert(3) }
        defer { second.cancel(); third.cancel() }
        try #require(await eventually { admittedCallers == [2, 3] })
        #expect(requests.entered == 1 && completed.isEmpty)
        requests.release(1)
        try #require(await eventually { requests.entered == 2 })
        #expect(model.loadState.isRunning, "The admitted latest round must remain running until its own response")
        #expect(completed.isEmpty && requests.active == 1)
        requests.release(2)
        await first.value
        await second.value
        await third.value
        #expect(completed == [1, 2, 3])
        #expect(requests.entered == 2 && requests.maximumActive == 1 && requests.active == 0,
                "Overlapping callers coalesce one later fetch and await its completion")
        if latestFails {
            #expect(model.loadState == .failed(GatewayError.message(for: GatewayError.closed("status round 2 failed"))))
            #expect(model.statuses.isEmpty)
        } else {
            #expect(model.loadState == .idle, "A successful latest fetch clears the previous round's failure")
            #expect(model.statuses == ["round-2": MCPServerStatus(name: "round-2", state: .connected,
                                                               toolCount: 1, tools: ["lookup"])])
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: [true, false]) func unqueuedFailureRemainsVisible(_ session: Bool) async throws {
        let requests = Requests(failures: [1], session: session)
        let model = model(requests)
        let task = Task { await model.load() }
        defer { requests.releaseAll(); task.cancel() }
        try #require(await eventually { requests.entered == 1 })
        #expect(model.loadState.isRunning)
        requests.release(1)
        await task.value
        #expect(model.loadState == .failed(GatewayError.message(for: GatewayError.closed("status round 1 failed"))))
        #expect(model.statuses.isEmpty && requests.entered == 1 && requests.maximumActive == 1)
    }
    @Test(.timeLimit(.minutes(2))) func successfulFirstRoundCannotMaskLatestFailure() async throws {
        let requests = Requests(failures: [2], session: true)
        let model = model(requests)
        let first = Task { await model.load() }
        defer { requests.releaseAll(); first.cancel() }
        try #require(await eventually { requests.entered == 1 })
        var queued = false
        let second = Task { queued = true; await model.load() }
        defer { second.cancel() }
        try #require(await eventually { queued })
        requests.release(1)
        try #require(await eventually { requests.entered == 2 })
        #expect(model.loadState.isRunning)
        #expect(model.statuses["round-1"]?.state == .connected)
        requests.release(2)
        await first.value; await second.value
        #expect(model.loadState == .failed(GatewayError.message(for: GatewayError.closed("status round 2 failed"))))
        #expect(model.statuses["round-1"]?.tools == ["lookup"])
        #expect(requests.entered == 2 && requests.maximumActive == 1)
    }

}
