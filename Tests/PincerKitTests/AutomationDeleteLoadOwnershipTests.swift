import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Automation delete versus held load", .timeLimit(.minutes(2)))
struct AutomationDeleteLoadOwnershipTests {
    enum Outcome: Sendable, Equatable { case unchanged, successfulDelete, failedDelete }
    actor Gate {
        var open = false, entered = false
        var entry: CheckedContinuation<Void, Never>?
        var held: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; entry?.resume(); entry = nil
            if !open { await withCheckedContinuation { held = $0 } }
        }
        func wait() async { if !entered, !open { await withCheckedContinuation { entry = $0 } } }
        func release() { open = true; entry?.resume(); entry = nil; held?.resume(); held = nil }
    }
    @MainActor final class Server {
        let gate = Gate()
        var lists = 0
        var removes: [(JSONValue, TimeInterval)] = []
        var failDelete = false
        var jobs: [JSONValue] = [
            ["id": "job-a", "name": "Daily briefing", "enabled": true, "createdAtMs": 1700000000000, "updatedAtMs": 1700000000000, "state": [:], "schedule": ["kind": "every", "everyMs": 60000],
             "sessionTarget": "isolated", "wakeMode": "now", "payload": ["kind": "agentTurn", "message": "Summarize updates"]],
            ["id": "job-b", "name": "Backup review", "enabled": true, "createdAtMs": 1700000000000, "updatedAtMs": 1700000000000, "state": [:], "schedule": ["kind": "every", "everyMs": 120000],
             "sessionTarget": "isolated", "wakeMode": "now", "payload": ["kind": "agentTurn", "message": "Review backups"]]
        ]
        func request(_ method: String, _ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue {
            switch method {
            case "cron.status": return ["enabled": true, "jobs": JSONValue(jobs.count)]
            case "cron.list":
                #expect(params["limit"]?.int == 200 && params["offset"]?.int == 0 && timeout == 30)
                lists += 1
                let snapshot: JSONValue = ["jobs": .array(jobs), "hasMore": false, "nextOffset": .null]
                if lists == 2 { await gate.hold() }
                return snapshot
            case "cron.remove":
                removes.append((params, timeout))
                if failDelete { throw GatewayError.notConnected }
                jobs.removeAll { $0["id"]?.string == params["id"]?.string }
                return ["ok": true, "removed": true]
            default: Issue.record("Unexpected actual automation method"); return [:]
            }
        }
    }

    @Test(arguments: [Outcome.unchanged, .successfulDelete, .failedDelete])
    func heldListCannotRestoreCompletedDelete(outcome: Outcome) async throws {
        let server = Server()
        let hello = GatewayHello(payload: ["auth": ["scopes": ["operator.admin"]],
                                           "features": ["methods": ["cron.list", "cron.status", "cron.remove"]]])
        let model = AutomationsModel(request: server.request, hello: { hello })
        await model.load()
        let selected = try #require(model.job("job-a"))
        #expect(model.jobs.map(\.id) == ["job-b", "job-a"])
        let actual = Task { await model.load() }
        defer { actual.cancel(); Task { await server.gate.release() } }
        await withTaskCancellationHandler {
            await server.gate.wait()
            #expect(model.loadState.isRunning)
            if outcome != .unchanged {
                server.failDelete = outcome == .failedDelete
                let removed = await model.remove(selected)
                #expect(removed == (outcome == .successfulDelete))
                #expect(server.removes.count == 1)
                #expect(server.removes.first?.0 == ["id": "job-a"] && server.removes.first?.1 == 60)
                if outcome == .successfulDelete { #expect(model.job("job-a") == nil) }
                else { #expect(model.job("job-a") != nil && model.operation(for: "job-a").error != nil) }
            }
            await server.gate.release()
            await actual.value
            #expect(model.job("job-b")?.name == "Backup review")
            #expect(model.loadState == .idle && model.hasLoaded)
            if outcome == .successfulDelete { #expect(model.job("job-a") == nil) }
            else { #expect(model.job("job-a")?.name == "Daily briefing") }
        } onCancel: { actual.cancel(); Task { await server.gate.release() } }
    }
    @Test
    func healthyRefreshAfterAcceptedDeletePublishesCurrentJobs() async throws {
        let server = Server()
        let hello = GatewayHello(payload: ["auth": ["scopes": ["operator.admin"]],
            "features": ["methods": ["cron.list", "cron.status", "cron.remove"]]])
        let model = AutomationsModel(request: server.request, hello: { hello })
        await model.load()
        let selected = try #require(model.job("job-a"))
        #expect(await model.remove(selected))
        await server.gate.release()
        var updated = server.jobs[0].object ?? [:]
            updated["name"] = .string("Updated backup review")
            server.jobs[0] = .object(updated)
        await model.load()
        #expect(model.job("job-a") == nil)
        #expect(model.job("job-b")?.name == "Updated backup review")
        #expect(model.loadState == .idle && model.hasLoaded)
    }

}
