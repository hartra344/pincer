import Foundation
import PincerKit

// Edge cases for `IntentService`: ids, defaults, error text, speech, reply waiting, connection
// lifetimes and several gateways, against scripted connections.

/// Lets deferred `connection.close()` tasks run.
@MainActor
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

@MainActor
private func expectError(_ expected: IntentError, _ label: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        check(false, "\(label) (no error)")
    } catch {
        check(error as? IntentError == expected, "\(label) (\(error.localizedDescription))")
    }
}

/// A second gateway with its own agent, unread chat and approval.
@MainActor
private func opsGateway() -> FakeIntentConnection {
    let connection = FakeIntentConnection()
    connection.responders["agents.list"] = { _ in json(#"{"defaultId":"ops","agents":[{"id":"ops","name":"Ops"}]}"#) }
    connection.responders["sessions.list"] = { _ in
        json(#"{"sessions":[{"key":"agent:ops:main","agentId":"ops","isMain":true,"label":"Deploy","unread":true,"lastActivityAt":9}]}"#)
    }
    connection.responders["exec.approval.list"] = { _ in
        json(#"{"approvals":[{"id":"w1","request":{"command":"kubectl rollout"},"expiresAtMs":9999999999999}]}"#)
    }
    return connection
}

@MainActor
func runIntentEdgeChecks(labels: UserDefaults, home: GatewayProfile, work: GatewayProfile) async {
    func service(_ profiles: [GatewayProfile], selected: UUID? = nil, identity: Bool = true,
                 connector: FakeIntentConnector = FakeIntentConnector()) -> IntentService
    {
        IntentService(profiles: profiles, hasIdentity: identity, selectedGatewayId: selected, connector: connector, labels: labels)
    }
    func finalMessage(_ text: String) -> [String: JSONValue] {
        ["message": .object(["role": "assistant", "content": .string(text)])]
    }

    // IDs
    for key in ["agent:main:main", "agent:main:discord:channel:1/2/3", "agent:main:x:/leading", "a:b:c:d:e"] {
        let parsed = IntentID.parse(IntentID.scoped(work.id, key))
        check(parsed?.gatewayId == work.id && parsed?.local == key, "id round-trips \(key)")
    }
    check(IntentID.parse(IntentID.scoped(home.id, "x"))?.gatewayId == home.id
          && IntentID.parse("\(home.id.uuidString.lowercased())/x")?.gatewayId == home.id, "lower-case gateway UUIDs parse")
    for bad in ["", "/", "/main", home.id.uuidString, "\(home.id.uuidString)/", "zzz/agent:main:main", "\(home.id.uuidString.dropLast())/x"] {
        check(IntentID.parse(bad) == nil, "malformed id rejected: '\(bad)'")
    }
    check(IntentID.gateway(home.id) == home.id.uuidString, "gateway id is the bare UUID")
    let listed = service([home, work]).gateways(for: [work.id.uuidString.lowercased(), UUID().uuidString, "nope"])
    check(listed.map(\.id) == [work.id], "gateway ids: case-insensitive, unknown dropped")

    // Default gateway resolution
    check((try? service([home]).resolveGateway(nil).id) == home.id, "one gateway resolves without a selection")
    check((try? service([home], selected: work.id).resolveGateway(nil).id) == home.id, "one gateway ignores a stale selection")
    check((try? service([home, work]).resolveGateway(nil).id) == home.id, "several gateways, no selection → first")
    check((try? service([home, work], selected: work.id).resolveGateway(nil).id) == work.id, "several gateways → selected")
    check((try? service([home, work], selected: home.id).resolveGateway(work.id).id) == work.id, "an explicit gateway wins over the selection")
    await expectError(.gatewayRemoved(name: "That Gateway"), "removed gateway without a name") {
        _ = try service([home]).resolveGateway(work.id)
    }
    let previousSelection = UserDefaults.standard.string(forKey: AppModel.selectedGatewayKey)
    UserDefaults.standard.set(work.id.uuidString, forKey: AppModel.selectedGatewayKey)
    check(IntentService.live(liveStore: { _ in nil }).selectedGatewayId == work.id, "live service reads selectedGatewayKey")
    UserDefaults.standard.set("not-a-uuid", forKey: AppModel.selectedGatewayKey)
    check(IntentService.live(liveStore: { _ in nil }).selectedGatewayId == nil, "a malformed selectedGatewayKey is ignored")
    UserDefaults.standard.set(previousSelection, forKey: AppModel.selectedGatewayKey)

    // Default agent from agents.list defaultId
    do {
        let connection = scriptedGateway()
        connection.responders["agents.list"] = { _ in
            json(#"{"defaultId":"research","agents":[{"id":"main","name":"Claw"},{"id":"research","name":"Scout"}]}"#)
        }
        connection.responders["sessions.list"] = { _ in
            json(#"{"sessions":[{"key":"agent:main:main","agentId":"main","isMain":true},{"key":"agent:research:main","agentId":"research","isMain":true,"label":"Scout main"}]}"#)
        }
        connection.responders["chat.send"] = { _ in ["runId": "r"] }
        let result = try await service([home], connector: FakeIntentConnector(connection: connection))
            .ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 60)
        check(result.agentName == "Scout" && result.chat.sessionKey == "agent:research:main"
              && connection.requests.last?.params["sessionKey"]?.string == "agent:research:main",
              "no agent → defaultId's main chat, not the first agent")
        connection.responders["agents.list"] = { _ in json(#"{"agents":[{"id":"research","name":"Scout"},{"id":"main"}]}"#) }
        let first = try await service([home], connector: FakeIntentConnector(connection: connection))
            .ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 60)
        check(first.agentName == "Scout", "no defaultId → the first agent")
        connection.responders["agents.list"] = { _ in json(#"{}"#) }
        let fallback = try await service([home], connector: FakeIntentConnector(connection: connection))
            .ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 60)
        check(fallback.chat.sessionKey == "agent:main:main" && fallback.agentName == "Main", "no agents at all → main")
    } catch {
        check(false, "default agent (\(error.localizedDescription))")
    }

    // Every error message
    let texts: [(IntentError, String)] = [
        (.noGateways, "Add a Gateway in Pincer first."),
        (.identityMissing, "Open Pincer once to finish setup."),
        (.gatewayRemoved(name: "Work"), "Work isn't in Pincer anymore."),
        (.awaitingPairing(gateway: "Work"), "Work needs this device approved. Run openclaw devices approve on the Gateway host."),
        (.connectFailed(gateway: "Work", message: "  unauthorized \n"), "Can't connect to Work: unauthorized."),
        (.connectFailed(gateway: "Work", message: "Denied!"), "Can't connect to Work: Denied!"),
        (.connectFailed(gateway: "Work", message: "Really?"), "Can't connect to Work: Really?"),
        (.unreachable(gateway: "Work"), "Work isn't reachable."),
        (.replyTimeout(agent: "Scout", seconds: 5), "Sent, but Scout hasn't replied within 5 seconds."),
        (.notFound(name: "Scout", gateway: "Work"), "Scout isn't on Work anymore."),
        (.sendFailed("unknown session"), "Couldn't send: unknown session"),
        (.runFailed("The run was stopped."), "The run was stopped."),
    ]
    for (error, text) in texts {
        check(error.localizedDescription == text && error.errorDescription == text, "error text: \(text)")
    }

    // Speech and summaries
    let exact = String(repeating: "abcd ", count: 100).trimmingCharacters(in: .whitespaces) + "e"
    check(exact.count == 500 && IntentService.spoken(exact) == exact, "exactly 500 characters aren't cut")
    let over = exact + "f"
    check(IntentService.spoken(over).hasSuffix("…") && !IntentService.spoken(over).contains("ef"), "501 characters are cut at a word")
    let oneWord = String(repeating: "x", count: 600)
    check(IntentService.spoken(oneWord) == String(repeating: "x", count: 500) + "…", "a single long word is cut at the limit")
    check(IntentService.spoken("one two three", limit: 7) == "one two…", "a cut on a word boundary keeps the last word")
    check(IntentService.spoken("one two three", limit: 6) == "one…", "a cut mid-word drops the partial word")
    check(IntentService.spoken("Done, then more text", limit: 8) == "Done…", "trailing punctuation dropped before the ellipsis")
    check(IntentService.spoken("") == "" && IntentService.spoken(" \n\t ") == "", "blank speech is empty")
    check(IntentService.spoken("a\tb\r\nc") == "a b c", "tabs and newlines collapse to spaces")
    check(IntentService.truncated("abc", 3) == "abc" && IntentService.truncated("abcd", 3) == "ab…", "truncation boundary")
    check(IntentService.truncated("first line\nsecond", 60) == "first line", "truncation keeps the first line")
    func chat(_ title: String, _ gateway: GatewayProfile = home) -> IntentChat {
        IntentChat(gatewayId: gateway.id, gatewayName: gateway.name, sessionKey: title, title: title, agentId: "main", agentName: "Claw")
    }
    check(IntentService.unreadSummary(["A", "B", "C", "D", "E", "F", "G"].map { chat($0) })
          == "7 unread chats: A, B, C, D, E, and 2 more.", "unread summary names five, then counts the rest")
    check(IntentService.unreadSummary(["A", "B", "C", "D", "E"].map { chat($0) }) == "5 unread chats: A, B, C, D, E.",
          "five unread chats all named")
    let ls = ExecApproval(json(#"{"id":"s","request":{"command":"ls -la"}}"#))!
    check(IntentService.approvalsSummary([IntentApproval(gatewayName: "Home", approval: ls)]) == "1 pending approval: ls -la",
          "singular approvals summary")

    // Unread and approval filters
    let rows = [
        SessionRow(json(#"{"key":"agent:main:dashboard:a","unread":true,"lastActivityAt":5}"#))!,
        SessionRow(json(#"{"key":"agent:main:dashboard:b","unread":true,"lastActivityAt":5}"#))!,
        SessionRow(json(#"{"key":"agent:main:dashboard:c","unread":true,"archived":true,"lastActivityAt":9}"#))!,
        SessionRow(json(#"{"key":"agent:main:subagent:d","unread":true,"lastActivityAt":9}"#))!,
        SessionRow(json(#"{"key":"agent:main:dashboard:e","unread":true,"spawnedBy":"agent:main:main","lastActivityAt":9}"#))!,
        SessionRow(json(#"{"key":"agent:main:dashboard:f","unread":false,"lastActivityAt":9}"#))!,
    ]
    check(IntentService.unreadRows(rows).map(\.key) == ["agent:main:dashboard:e", "agent:main:dashboard:a", "agent:main:dashboard:b"],
          "unread excludes archived, :subagent: keys and read chats, like totalUnread; ties sorted by key")
    let now = Date()
    let nowMs = Int(now.timeIntervalSince1970 * 1000)
    let soon = ExecApproval(json(#"{"id":"soon","request":{"command":"a"},"expiresAtMs":\#(nowMs + 60_000)}"#))!
    let past = ExecApproval(json(#"{"id":"past","request":{"command":"b"},"expiresAtMs":\#(nowMs - 1)}"#))!
    check(IntentService.pending([soon, past], at: now).map(\.id) == ["soon"], "an approval expired a moment ago is dropped")
    check(IntentService.pending([soon], at: now.addingTimeInterval(120)).isEmpty, "approvals expire as time passes")

    // Reply collector
    do {
        let collector = ReplyCollector(sessionKey: "k")
        collector.handle(GatewayEvent(name: "agent", payload: ["runId": "r", "state": "final"], seq: nil))
        collector.handle(GatewayEvent(name: "chat", payload: ["runId": "r", "state": "delta"], seq: nil))
        collector.handle(GatewayEvent(name: "chat", payload: ["runId": "r", "state": "final"], seq: nil))
        let buffered = await collector.wait(runId: "r", timeout: 0.1)
        check(buffered == .final(nil), "final without a sessionKey is accepted and buffered; other events ignored")
        let missing = await collector.wait(runId: "r", timeout: 0.1)
        check(missing == nil, "a buffered outcome is consumed once; later waits time out")
        collector.handle(GatewayEvent(name: "chat", payload: ["state": "final"], seq: nil))
        let noRun = await collector.wait(runId: "", timeout: 0.1)
        check(noRun == nil, "events without a runId are ignored")
    }

    // Deltas, then final, after the send response
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { [weak connection] params in
            let key = params["sessionKey"]?.string ?? ""
            Task { @MainActor in
                for (index, piece) in ["Po", "ng", "!"].enumerated() {
                    try? await Task.sleep(for: .milliseconds(20))
                    connection?.chatEvent(runId: "run-d", sessionKey: key, state: "delta", extra: ["deltaText": .string(piece), "seq": .number(Double(index))])
                }
                connection?.chatEvent(runId: "run-d", sessionKey: key, state: "final", extra: finalMessage("Pong!"))
            }
            return ["runId": "run-d"]
        }
        let result = try await service([home], connector: FakeIntentConnector(connection: connection))
            .ask("ping", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 5)
        check(result.text == "Pong!" && connection.observerCount == 0, "deltas then final → the final text")
    } catch {
        check(false, "deltas then final (\(error.localizedDescription))")
    }

    // No runId in the response → the idempotency key identifies the run
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { [weak connection] params in
            connection?.chatEvent(runId: params["idempotencyKey"]?.string ?? "", sessionKey: params["sessionKey"]?.string ?? "",
                                  state: "final", extra: finalMessage("by key"))
            return ["status": "started"]
        }
        let result = try await service([home], connector: FakeIntentConnector(connection: connection))
            .ask("q", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 5)
        check(result.text == "by key", "without a runId the idempotency key is the run id")
    } catch {
        check(false, "idempotency run id (\(error.localizedDescription))")
    }

    // Run error / aborted variants
    let outcomes: [(String, [String: JSONValue], IntentError, String)] = [
        ("error", [:], .runFailed("The run failed."), "run error without a message"),
        ("error", ["errorMessage": ""], .runFailed("The run failed."), "run error with an empty message"),
        ("aborted", [:], .runFailed("The run was stopped."), "aborted without a reason"),
        ("aborted", ["stopReason": "Stopped from the dashboard"], .runFailed("Stopped from the dashboard"), "aborted with a stop reason"),
        ("aborted", ["errorMessage": "Timed out", "stopReason": "x"], .runFailed("Timed out"), "aborted prefers errorMessage"),
    ]
    for (state, extra, expected, label) in outcomes {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { [weak connection] params in
            connection?.chatEvent(runId: "r", sessionKey: params["sessionKey"]?.string ?? "", state: state, extra: extra)
            return ["runId": "r"]
        }
        await expectError(expected, label) {
            _ = try await service([home], connector: FakeIntentConnector(connection: connection))
                .ask("q", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 5)
        }
        check(connection.observerCount == 0 && connection.closeCount == 1, "\(label): listener removed, connection closed once")
    }

    // Reply timeout: the message was sent
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { _ in ["runId": "slow"] }
        let started = Date()
        do {
            _ = try await service([home], connector: FakeIntentConnector(connection: connection))
                .ask("q", agentId: "research", agentName: "Scout", gatewayId: nil, waitForReply: true, timeoutSeconds: 5)
            check(false, "timeout throws")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            check(error.localizedDescription == "Sent, but Scout hasn't replied within 5 seconds." && elapsed >= 4.5 && elapsed < 8,
                  "reply timeout names the agent and says it was sent (\(String(format: "%.1f", elapsed)) s)")
            check(connection.requests.filter { $0.method == "chat.send" }.count == 1 && connection.observerCount == 0
                  && connection.closeCount == 1, "timeout: sent once, listener removed, connection closed")
        }
    }

    // Connect failures across every action
    for failure in [IntentError.awaitingPairing(gateway: "Home"), .connectFailed(gateway: "Home", message: "unauthorized")] {
        let failing = service([home], connector: FakeIntentConnector(failures: [home.id: failure]))
        await expectError(failure, "send: \(failure.localizedDescription)") { try await failing.send("x", to: chat("agent:main:main")) }
        await expectError(failure, "start chat: \(failure.localizedDescription)") {
            _ = try await failing.startChat(agentId: "main", agentName: "Claw", gatewayId: home.id, message: nil)
        }
        await expectError(failure, "unread: \(failure.localizedDescription)") { _ = try await failing.unreadChats(gatewayId: nil) }
        await expectError(failure, "approvals: \(failure.localizedDescription)") { _ = try await failing.pendingApprovals(gatewayId: nil) }
    }
    await expectError(.noGateways, "unread with no gateways") { _ = try await service([]).unreadChats(gatewayId: nil) }
    await expectError(.noGateways, "approvals with no gateways") { _ = try await service([]).pendingApprovals(gatewayId: nil) }
    await expectError(.noGateways, "ask with no gateways") {
        _ = try await service([]).ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 5)
    }
    await expectError(.gatewayRemoved(name: "Work"), "send to a chat on a removed gateway") {
        try await service([home]).send("x", to: chat("agent:main:main", work))
    }
    let bothDown = service([home, work], connector: FakeIntentConnector(failures: [
        home.id: .awaitingPairing(gateway: "Home"), work.id: .unreachable(gateway: "Work"),
    ]))
    await expectError(.awaitingPairing(gateway: "Home"), "every gateway failing → the first failure") {
        _ = try await bothDown.pendingApprovals(gatewayId: nil)
    }
    await expectError(.identityMissing, "no identity → open Pincer once (ask)") {
        _ = try await service([home], identity: false, connector: FakeIntentConnector(connection: scriptedGateway()))
            .ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 5)
    }
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { _ in ["runId": "r"] }
        _ = try await service([GatewayProfile.demo()], identity: false, connector: FakeIntentConnector(connection: connection))
            .ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 5)
        check(true, "the demo gateway works before pairing")
    } catch {
        check(false, "demo without identity (\(error.localizedDescription))")
    }
    do {
        _ = try await GatewayIntentConnector(identity: { nil }).connect(home, timeout: 1)
        check(false, "connector without identity throws")
    } catch {
        check(error as? IntentError == .identityMissing, "connector without identity → identityMissing")
    }
    check(GatewayIntentConnector().liveTargets(home.id) == nil && GatewayIntentConnector().liveApprovals(home.id) == nil,
          "no app store → no live targets")

    // Every action closes its connection
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { _ in ["runId": "r"] }
        connection.responders["exec.approval.list"] = { _ in json(#"{"approvals":[]}"#) }
        let closing = service([home], connector: FakeIntentConnector(connection: connection))
        _ = try await closing.ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 5)
        try await closing.send("x", to: chat("agent:main:main"))
        _ = try await closing.startChat(agentId: "main", agentName: "Claw", gatewayId: home.id, message: nil)
        _ = try await closing.unreadChats(gatewayId: nil)
        _ = try await closing.pendingApprovals(gatewayId: nil)
        _ = try? await closing.ask("q", agentId: "ghost", gatewayId: nil, waitForReply: false, timeoutSeconds: 5)
        _ = await closing.suggestedAgents()
        await settle()
        check(connection.closeCount == 7 && connection.observerCount == 0, "every action closes its connection (\(connection.closeCount)/7)")
    } catch {
        check(false, "connection lifetimes (\(error.localizedDescription))")
    }

    // Start chat edge cases
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { _ in ["runId": "r"] }
        let starting = service([home], connector: FakeIntentConnector(connection: connection))
        _ = try await starting.startChat(agentId: "main", agentName: "Claw", gatewayId: home.id, message: "  \n ")
        check(!connection.requests.contains { $0.method == "chat.send" }, "a blank first message isn't sent")
        connection.responders["sessions.create"] = { _ in throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown agent", details: nil) }
        await expectError(.notFound(name: "Ghost", gateway: "Home"), "start chat with an unknown agent → not found") {
            _ = try await starting.startChat(agentId: "ghost", agentName: "Ghost", gatewayId: home.id, message: nil)
        }
        connection.responders["sessions.create"] = { _ in json(#"{"ok":true}"#) }
        await expectError(.sendFailed("the Gateway didn't create a chat."), "start chat without a key → send failed") {
            _ = try await starting.startChat(agentId: "main", agentName: "Claw", gatewayId: home.id, message: nil)
        }
        connection.responders["sessions.create"] = { _ in json(#"{"key":"agent:main:dashboard:bare"}"#) }
        let bare = try await starting.startChat(agentId: "main", agentName: "Claw", gatewayId: home.id, message: nil)
        check(bare.sessionKey == "agent:main:dashboard:bare", "start chat with only a key in the response")
        let liveOnly = service([home], connector: FakeIntentConnector(connection: connection, live: [home.id: GatewayTargets(
            agents: [AgentSummary(id: "main", name: "Claw", emoji: nil)], defaultAgentId: "main", sessions: [])]))
        await expectError(.notFound(name: "Scout", gateway: "Home"), "start chat with an agent the app no longer lists") {
            _ = try await liveOnly.startChat(agentId: "research", agentName: "Scout", gatewayId: home.id, message: nil)
        }
    } catch {
        check(false, "start chat edges (\(error.localizedDescription))")
    }

    // Send: failures that aren't a missing session keep their reason; live state catches deleted chats early
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "agent busy", details: nil) }
        await expectError(.sendFailed("agent busy [UNAVAILABLE]"), "send failure keeps its reason") {
            try await service([home], connector: FakeIntentConnector(connection: connection)).send("x", to: chat("agent:main:main"))
        }
        connection.responders["chat.send"] = { _ in throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Session not found", details: nil) }
        await expectError(.notFound(name: "agent:main:main", gateway: "Home"), "'session not found' → not found") {
            try await service([home], connector: FakeIntentConnector(connection: connection)).send("x", to: chat("agent:main:main"))
        }
        let live = GatewayTargets(agents: [], defaultAgentId: "main", sessions: [SessionRow(json(#"{"key":"agent:main:main"}"#))!])
        let before = connection.requests.count
        await expectError(.notFound(name: "Gone", gateway: "Home"), "send to a chat the app no longer lists") {
            try await service([home], connector: FakeIntentConnector(connection: connection, live: [home.id: live])).send("x", to: chat("Gone"))
        }
        check(connection.requests.count == before, "nothing sent to a chat the app no longer lists")
    }

    // Several gateways: results tagged with the right gateway
    do {
        let homeConnection = scriptedGateway()
        let workConnection = opsGateway()
        homeConnection.responders["exec.approval.list"] = { _ in
            json(#"{"approvals":[{"id":"h1","request":{"command":"make"},"expiresAtMs":9999999999999}]}"#)
        }
        let both = service([home, work], connector: FakeIntentConnector(connections: [home.id: homeConnection, work.id: workConnection]))
        let unread = try await both.unreadChats(gatewayId: nil)
        check(unread.map(\.title) == ["Trip", "Claw", "Deploy"], "unread from both gateways (\(unread.map(\.title)))")
        check(unread.allSatisfy { ($0.title == "Deploy") == ($0.gatewayId == work.id) }
              && unread.first { $0.title == "Deploy" }?.subtitle == "Ops · Work"
              && unread.first { $0.title == "Trip" }?.subtitle == "Claw · Home"
              && unread.allSatisfy { IntentID.parse($0.entityID)?.gatewayId == $0.gatewayId && IntentID.parse($0.entityID)?.local == $0.sessionKey },
              "each unread chat is tagged with its own gateway")
        let onlyWork = try await both.unreadChats(gatewayId: work.id)
        check(onlyWork.map(\.title) == ["Deploy"], "unread for one chosen gateway")
        let approvals = try await both.pendingApprovals(gatewayId: nil)
        check(approvals.map { "\($0.gatewayName):\($0.approval.id)" } == ["Home:h1", "Work:w1"], "approvals tagged with their gateway")
        let agents = await both.suggestedAgents()
        check(agents.map { "\($0.subtitle ?? "-"):\($0.agentId)" } == ["Home:main", "Home:research", "Work:ops"],
              "agents from both gateways name their gateway")
        let resolved = both.agents(for: agents.map(\.entityID))
        check(resolved.map(\.gatewayId) == [home.id, home.id, work.id], "agent ids resolve back to their gateway")
        workConnection.responders["chat.send"] = { _ in ["runId": "w"] }
        let askWork = try? await both.ask("q", agentId: "ops", gatewayId: work.id, waitForReply: false, timeoutSeconds: 5)
        check(askWork?.chat.gatewayId == work.id && askWork?.chat.sessionKey == "agent:ops:main"
              && workConnection.requests.contains { $0.method == "chat.send" }
              && !homeConnection.requests.contains { $0.method == "chat.send" },
              "ask goes to the chosen gateway's connection only")
        let liveAndFetched = service([home, work], connector: FakeIntentConnector(
            connections: [work.id: workConnection],
            live: [home.id: GatewayTargets(agents: [], defaultAgentId: "main",
                                           sessions: [SessionRow(json(#"{"key":"agent:main:main","label":"Live main","unread":true}"#))!])],
            approvals: [home.id: [soon, past]]))
        let mixed = try await liveAndFetched.unreadChats(gatewayId: nil)
        check(mixed.map(\.title) == ["Live main", "Deploy"], "the app's live chats combine with a fetched gateway")
        let mixedApprovals = try await liveAndFetched.pendingApprovals(gatewayId: nil)
        check(mixedApprovals.map(\.approval.id) == ["soon", "w1"], "live approvals filter expired ones too")
    } catch {
        check(false, "several gateways (\(error.localizedDescription))")
    }

    await runIntentReviewChecks(labels: labels, home: home, work: work)
}

/// Product-review fixes: main chats named after agents, parallel suggestions, spoken errors,
/// name-cache trimming and removed-gateway names.
@MainActor
private func runIntentReviewChecks(labels: UserDefaults, home: GatewayProfile, work: GatewayProfile) async {
    func service(_ profiles: [GatewayProfile], connector: FakeIntentConnector = FakeIntentConnector(),
                 labels: UserDefaults = labels) -> IntentService
    {
        IntentService(profiles: profiles, hasIdentity: true, selectedGatewayId: nil, connector: connector, labels: labels)
    }

    // Main chats are named after their agent; renamed ones keep their name.
    do {
        let connection = FakeIntentConnection()
        connection.responders["agents.list"] = { _ in
            json(#"{"defaultId":"main","agents":[{"id":"main","name":"Claw"},{"id":"research","name":"Scout"},{"id":"coder","name":"Forge"}]}"#)
        }
        connection.responders["sessions.list"] = { _ in
            json(#"""
            {"sessions":[
              {"key":"agent:main:main","agentId":"main","isMain":true,"label":"Main","unread":true,"lastActivityAt":9},
              {"key":"agent:research:main","agentId":"research","isMain":true,"derivedTitle":"main","unread":true,"lastActivityAt":8},
              {"key":"agent:coder:main","agentId":"coder","isMain":true,"label":"Home base","unread":true,"lastActivityAt":7},
              {"key":"agent:main:dashboard:main","agentId":"main","label":"Main","unread":true,"isMain":false,"lastActivityAt":6}
            ]}
            """#)
        }
        let naming = service([home], connector: FakeIntentConnector(connection: connection))
        let unread = try await naming.unreadChats(gatewayId: nil)
        check(unread.map(\.title) == ["Claw", "Scout", "Home base", "Main"],
              "main chats take their agent's name; renamed and non-main chats keep theirs (\(unread.map(\.title)))")
        check(IntentService.unreadSummary(unread) == "4 unread chats: Claw, Scout, Home base, Main.",
              "spoken unread summary names agents, not Main, Main")
        let suggested = await naming.suggestedChats()
        check(suggested.first { $0.sessionKey == "agent:research:main" }?.title == "Scout", "suggested main chat named after its agent")
        check(naming.chats(for: [IntentID.scoped(home.id, "agent:research:main")]).first?.title == "Scout",
              "offline lookup uses the remembered agent name")
        let (fresh, freshName) = scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: freshName) }
        let offline = service([home], labels: fresh).chats(for: [IntentID.scoped(home.id, "agent:coder:main"),
                                                                  IntentID.scoped(home.id, "agent:coder:dashboard:x")])
        check(offline.map(\.title) == ["Coder", "dashboard:x"], "offline without a name: main chat named from its agent id (\(offline.map(\.title)))")
        connection.responders["chat.send"] = { _ in ["runId": "r"] }
        let result = try await naming.ask("q", agentId: "research", gatewayId: nil, waitForReply: false, timeoutSeconds: 5)
        check(result.chat.title == "Scout", "Ask returns its main chat named after the agent")
    } catch {
        check(false, "main chat names (\(error.localizedDescription))")
    }

    // Suggestions query every gateway at once.
    do {
        let profiles = (1...4).map { GatewayProfile(name: "GW \($0)", url: "ws://127.0.0.1:\($0)", authMode: .none) }
        var connections: [UUID: FakeIntentConnection] = [:]
        for (index, profile) in profiles.enumerated() {
            let connection = FakeIntentConnection()
            connection.responders["agents.list"] = { _ in
                try await Task.sleep(for: .milliseconds(700))
                return json(#"{"agents":[{"id":"a\#(index)","name":"Agent \#(index)"}]}"#)
            }
            connection.responders["sessions.list"] = { _ in
                json(#"{"sessions":[{"key":"agent:a\#(index):dashboard:c","agentId":"a\#(index)","label":"Chat \#(index)"}]}"#)
            }
            connections[profile.id] = connection
        }
        let parallel = service(profiles, connector: FakeIntentConnector(connections: connections))
        var started = Date()
        let agents = await parallel.suggestedAgents()
        let agentsTime = Date().timeIntervalSince(started)
        check(agents.map(\.name) == ["Agent 0", "Agent 1", "Agent 2", "Agent 3"] && agentsTime < 2,
              "agent suggestions from 4 slow gateways in parallel, in gateway order (\(String(format: "%.2f", agentsTime)) s)")
        started = Date()
        let chats = await parallel.chats(matching: "chat")
        let chatsTime = Date().timeIntervalSince(started)
        check(chats.map(\.title) == ["Chat 0", "Chat 1", "Chat 2", "Chat 3"] && chatsTime < 2,
              "chat search across 4 slow gateways in parallel (\(String(format: "%.2f", chatsTime)) s)")
        started = Date()
        let matching = await parallel.agents(matching: "agent 2")
        check(matching.map(\.agentId) == ["a2"] && Date().timeIntervalSince(started) < 2, "agent search in parallel")

        for connection in connections.values {
            connection.responders["agents.list"] = { _ in
                try await Task.sleep(for: .seconds(3))
                return [:]
            }
        }
        let bounded = service(profiles, connector: FakeIntentConnector(connections: connections))
        bounded.suggestionTimeout = 0.5
        started = Date()
        let none = await bounded.suggestedAgents()
        let boundTime = Date().timeIntervalSince(started)
        check(none.isEmpty && boundTime < 1.5, "one suggestion bound for all gateways, not one each (\(String(format: "%.2f", boundTime)) s)")
        let mixed = service([home] + profiles.prefix(1), connector: FakeIntentConnector(
            connections: [profiles[0].id: connections[profiles[0].id]!], failures: [home.id: .unreachable(gateway: "Home")]))
        mixed.suggestionTimeout = 0.5
        let partial = await mixed.suggestedAgents()
        check(partial.isEmpty, "unreachable and slow gateways both skipped")
    }

    // Spoken errors: no trailing Gateway codes, no backticks.
    let spoken: [(IntentError, String)] = [
        (.connectFailed(gateway: "Work", message: "unauthorized [AUTH_TOKEN_MISMATCH]"), "Can't connect to Work: unauthorized."),
        (.connectFailed(gateway: "Work", message: "pairing required (requestId: p1) [PAIRING_REQUIRED]  "),
         "Can't connect to Work: pairing required (requestId: p1)."),
        (.sendFailed("agent busy [UNAVAILABLE]"), "Couldn't send: agent busy"),
        (.sendFailed("bad [code] here"), "Couldn't send: bad [code] here"),
        (.sendFailed("use [beta]"), "Couldn't send: use [beta]"),
        (.sendFailed("[X] at start [INVALID_REQUEST]"), "Couldn't send: [X] at start"),
        (.runFailed("Model overloaded [RATE_LIMIT_429]"), "Model overloaded"),
        (.runFailed("Model overloaded"), "Model overloaded"),
    ]
    for (error, text) in spoken {
        check(error.localizedDescription == text, "spoken error: \(text) (\(error.localizedDescription))")
    }
    let pairing = IntentError.awaitingPairing(gateway: "Home").localizedDescription
    check(pairing == "Home needs this device approved. Run openclaw devices approve on the Gateway host." && !pairing.contains("`"),
          "pairing message has no backticks")
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "agent busy", details: nil) }
        do {
            try await service([home], connector: FakeIntentConnector(connection: connection)).send("x", to: IntentChat(
                gatewayId: home.id, gatewayName: "Home", sessionKey: "agent:main:main", title: "Claw", agentId: "main", agentName: "Claw"))
            check(false, "busy send throws")
        } catch {
            check(error.localizedDescription == "Couldn't send: agent busy", "a real RPC failure is spoken without its code (\(error.localizedDescription))")
        }
    }

    // Name cache: over the limit, what was just listed is kept.
    do {
        let (cache, cacheName) = scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: cacheName) }
        var old: [String: [String]] = [:]
        for index in 0..<1000 { old["\(UUID().uuidString)/agent-\(index)"] = ["Old \(index)", ""] }
        cache.set(old, forKey: "pincer.intents.labels")
        let listing = service([home], connector: FakeIntentConnector(connection: scriptedGateway()), labels: cache)
        let agents = await listing.suggestedAgents()
        let chats = await listing.suggestedChats()
        let stored = cache.dictionary(forKey: "pincer.intents.labels") as? [String: [String]] ?? [:]
        let listed = agents.map(\.entityID) + chats.map(\.entityID)
        check(stored.count == 1000 && listed.allSatisfy { stored[$0] != nil },
              "name cache stays at 1000 and keeps the latest listing (\(stored.count), \(listed.filter { stored[$0] == nil }.count) missing)")
        check(service([home], labels: cache).agents(for: [IntentID.scoped(home.id, "research")]).first?.name == "Scout",
              "freshly listed names survive trimming")
    }

    // A removed gateway's error names it when the Shortcut knows the name.
    let one = service([home], connector: FakeIntentConnector(connection: scriptedGateway()))
    let removed = IntentError.gatewayRemoved(name: "Work")
    for (label, body) in [
        ("ask", { _ = try await one.ask("q", agentId: "main", gatewayId: work.id, gatewayName: "Work", waitForReply: false, timeoutSeconds: 5) }),
        ("start chat", { _ = try await one.startChat(agentId: "main", agentName: "Claw", gatewayId: work.id, gatewayName: "Work", message: nil) }),
        ("unread", { _ = try await one.unreadChats(gatewayId: work.id, gatewayName: "Work") }),
        ("approvals", { _ = try await one.pendingApprovals(gatewayId: work.id, gatewayName: "Work") }),
    ] as [(String, () async throws -> Void)] {
        do {
            try await body()
            check(false, "\(label) on a removed gateway throws")
        } catch {
            check(error as? IntentError == removed && error.localizedDescription == "Work isn't in Pincer anymore.",
                  "\(label): removed gateway named (\(error.localizedDescription))")
        }
    }
    do {
        _ = try await one.unreadChats(gatewayId: work.id)
        check(false, "unnamed removed gateway throws")
    } catch {
        check(error.localizedDescription == "That Gateway isn't in Pincer anymore.", "without a name: That Gateway")
    }
}
