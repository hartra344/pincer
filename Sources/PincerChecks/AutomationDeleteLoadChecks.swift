import Foundation
@testable import PincerKit

private actor AutomationListGate {
    private var open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        if !self.open { await withCheckedContinuation { self.held = $0 } }
    }
    func release() { self.open = true; self.held?.resume(); self.held = nil }
}

@MainActor private final class AutomationDeleteFixture {
    let gate = AutomationListGate()
    var lists = 0, removes = 0
    var didHold = false
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
            check(params["limit"]?.int == 200 && params["offset"]?.int == 0 && timeout == 30, "actual automation list keeps existing params/timeout")
            lists += 1
            let snapshot: JSONValue = ["jobs": .array(jobs), "hasMore": false, "nextOffset": .null]
            if lists == 2 { didHold = true; await gate.hold() }
            return snapshot
        case "cron.remove":
            removes += 1
            check(params == ["id": "job-a"] && timeout == 60, "actual delete sends exact existing cron.remove id/timeout")
            if failDelete { throw GatewayError.notConnected }
            jobs.removeAll { $0["id"]?.string == "job-a" }
            return ["ok": true, "removed": true]
        default: throw GatewayError.notConnected
        }
    }
}

@MainActor func runAutomationDeleteLoadChecks() async {
    for outcome in 0..<3 { // unchanged / accepted deletion / failed deletion
        let fixture = AutomationDeleteFixture()
        fixture.failDelete = outcome == 2
        let hello = GatewayHello(payload: ["auth": ["scopes": ["operator.admin"]],
                "features": ["methods": ["cron.list", "cron.status", "cron.remove"]]])
        let model = AutomationsModel(request: fixture.request, hello: { hello })
        await model.load()
        guard let selected = model.job("job-a") else { check(false, "ordinary actual automation load publishes fixture"); return }
        let actual = Task { await model.load() }
        defer { actual.cancel(); Task { await fixture.gate.release() } }
        await withTaskCancellationHandler {
            let held = await waitFor("actual fixture cron.list snapshot is held", timeout: 30) { fixture.didHold }
            check(held, "actual fixture list reaches the held response boundary")
            guard held, !Task.isCancelled else {
                actual.cancel()
                await fixture.gate.release()
                await actual.value
                return
            }
            if outcome != 0 {
                let removed = await model.remove(selected)
                check(removed == (outcome == 1), "actual remove returns its accepted/failed outcome")
                check(fixture.removes == 1, "one actual mutation request is admitted")
            }
            await fixture.gate.release()
            await actual.value
            check(model.job("job-b")?.name == "Backup review", "held list retains independent automation")
            check((model.job("job-a") == nil) == (outcome == 1), "held list cannot restore successful deletion; ordinary/failed-delete rows remain")
            check(model.loadState == .idle && model.hasLoaded, "actual held load reaches terminal completion")
            var updated = fixture.jobs[0].object ?? [:]
            updated["name"] = .string("Updated remaining automation")
            fixture.jobs[0] = .object(updated)
            await model.load()
            check(model.jobs.contains { $0.name == "Updated remaining automation" }, "fresh healthy list publishes after held-load completion")
            check((model.job("job-a") == nil) == (outcome == 1), "fresh load preserves actual successful/failed deletion outcome")
        } onCancel: { actual.cancel(); Task { await fixture.gate.release() } }
    }
}

@MainActor private final class AutomationLiveRequests {
    let connection: GatewayConnection
    let gate = AutomationListGate()
    var holdNext = false
    var didHold = false
    init(_ connection: GatewayConnection) { self.connection = connection }
    func request(_ method: String, _ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue {
        let result = try await self.connection.request(method, params, timeout: timeout)
        if method == "cron.list", self.holdNext {
            self.holdNext = false
            self.didHold = true
            await self.gate.hold() // Hold the real returned snapshot; no payload overlay or invented fields.
        }
        return result
    }
}

@MainActor func runLiveAutomationDeleteLoadChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Automation delete ownership", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let connection = GatewayConnection(profile: profile)
    let hello = Scripted<GatewayHello?>(nil)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, value in
        if state.isConnected { Task { @MainActor in hello.value = value } }
    })
    await connection.start()
    defer { Task { await connection.stop() } }
    let connected = await waitFor("automation deletion mock connection", timeout: 30) { hello.value != nil }
    check(connected, "fresh mock automation ownership connection is ready")
    guard connected, hello.value?.methods.contains("cron.list") == true,
          hello.value?.scopes.contains("operator.admin") == true else {
        check(false, "fresh mock advertises existing cron methods and grants admin for fixture writes"); return
    }
    var draft = CronJobDraft(agentId: "main")
    draft.name = "Held list ownership \(UUID().uuidString.prefix(8))"
    draft.message = "Review the morning briefing"
    do {
        let created = try await connection.request("cron.add", draft.addParams, timeout: 60)
        guard let added = CronJob(created["job"] ?? created) else { check(false, "actual cron.add returns a job"); return }
        defer { Task { _ = try? await connection.request("cron.remove", ["id": .string(added.id)], timeout: 60) } }
        let requests = AutomationLiveRequests(connection)
        let model = AutomationsModel(request: requests.request, hello: { hello.value })
        await model.load()
        check(model.job(added.id) != nil, "actual fresh-mock list includes newly created automation")
        let otherIDs = Set(model.jobs.map(\.id)).subtracting([added.id])
        requests.holdNext = true
        let actual = Task { await model.load() }
        defer { actual.cancel(); Task { await requests.gate.release() } }
        await withTaskCancellationHandler {
            let held = await waitFor("actual returned cron.list snapshot is held", timeout: 30) { requests.didHold }
            check(held, "actual list reaches the held response boundary")
            guard held else { await requests.gate.release(); await actual.value; return }
            let removed = await model.remove(added)
            check(removed && model.job(added.id) == nil, "actual cron.remove completes before old real list is released")
            await requests.gate.release()
            await actual.value
            check(model.job(added.id) == nil, "released old real cron.list cannot resurrect completed deletion")
            check(otherIDs.isSubset(of: Set(model.jobs.map(\.id))), "independent real mock automations remain after deletion")
            await model.load()
            check(model.job(added.id) == nil && otherIDs.isSubset(of: Set(model.jobs.map(\.id))), "fresh healthy real list publishes after accepted deletion")
        } onCancel: { actual.cancel(); Task { await requests.gate.release() } }
    } catch { check(false, "actual fresh-mock automation fixture RPCs complete") }
}
