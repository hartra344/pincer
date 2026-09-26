import Foundation
import PincerKit

// Shortcuts / Siri: `IntentService` against a scripted connection, the demo and a (mock) Gateway.

/// A scripted Gateway connection: canned responses per method, and events pushed on demand.
@MainActor
final class FakeIntentConnection: IntentConnection {
    var responders: [String: @MainActor (JSONValue) async throws -> JSONValue] = [:]
    private(set) var requests: [(method: String, params: JSONValue)] = []
    private var observers: [Int: @MainActor (GatewayEvent) -> Void] = [:]
    private var nextToken = 0
    private(set) var closed = false
    private(set) var closeCount = 0
    var observerCount: Int { self.observers.count }

    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        self.requests.append((method, params))
        guard let responder = self.responders[method] else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method \(method)", details: nil)
        }
        return try await responder(params)
    }

    func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int {
        self.nextToken += 1
        self.observers[self.nextToken] = handler
        return self.nextToken
    }

    func stopObserving(_ token: Int) { self.observers.removeValue(forKey: token) }

    func close() async {
        self.closed = true
        self.closeCount += 1
    }

    func emit(_ name: String, _ payload: JSONValue) {
        for observer in self.observers.values { observer(GatewayEvent(name: name, payload: payload, seq: nil)) }
    }

    func chatEvent(runId: String, sessionKey: String, state: String, extra: [String: JSONValue] = [:]) {
        var payload: [String: JSONValue] = ["runId": .string(runId), "sessionKey": .string(sessionKey), "state": .string(state)]
        payload.merge(extra) { $1 }
        self.emit("chat", .object(payload))
    }
}

@MainActor
struct FakeIntentConnector: IntentConnector {
    var connection: FakeIntentConnection?
    /// Per-gateway connections, used before `connection`.
    var connections: [UUID: FakeIntentConnection] = [:]
    var failures: [UUID: IntentError] = [:]
    var live: [UUID: GatewayTargets] = [:]
    var approvals: [UUID: [ExecApproval]] = [:]

    func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection {
        if let failure = self.failures[profile.id] { throw failure }
        guard let connection = self.connections[profile.id] ?? self.connection else { throw IntentError.unreachable(gateway: profile.name) }
        return connection
    }

    func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { self.live[gatewayId] }
    func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { self.approvals[gatewayId] }
}

/// A gateway with a `main` and `research` agent; `research` has no main chat.
@MainActor
func scriptedGateway() -> FakeIntentConnection {
    let connection = FakeIntentConnection()
    connection.responders["agents.list"] = { _ in
        json(#"{"defaultId":"main","agents":[{"id":"main","identity":{"name":"Claw","emoji":"🦞"}},{"id":"research","name":"Scout"}]}"#)
    }
    connection.responders["sessions.list"] = { _ in
        json(#"""
        {"sessions":[
          {"key":"agent:main:main","agentId":"main","isMain":true,"label":"Main","unread":true,"lastActivityAt":3},
          {"key":"agent:main:dashboard:trip","agentId":"main","label":"Trip","unread":true,"lastActivityAt":5},
          {"key":"agent:main:subagent:x","agentId":"main","label":"Helper","unread":true,"parentSessionKey":"agent:main:main","spawnedBy":"agent:main:main"},
          {"key":"agent:main:dashboard:old","agentId":"main","label":"Old","unread":true,"archived":true}
        ]}
        """#)
    }
    connection.responders["sessions.create"] = { params in
        let agent = params["agentId"]?.string ?? "main"
        return json(#"{"key":"agent:\#(agent):dashboard:new","session":{"key":"agent:\#(agent):dashboard:new","agentId":"\#(agent)","derivedTitle":"New session"}}"#)
    }
    return connection
}

@MainActor
func runIntentChecks() async {
    let (labels, labelsName) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: labelsName) }
    let home = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
    let work = GatewayProfile(name: "Work", url: "wss://work.tail1234.ts.net", authMode: .token)
    func service(_ profiles: [GatewayProfile], selected: UUID? = nil, identity: Bool = true,
                 connector: FakeIntentConnector = FakeIntentConnector()) -> IntentService
    {
        IntentService(profiles: profiles, hasIdentity: identity, selectedGatewayId: selected, connector: connector, labels: labels)
    }

    // IDs
    let colonKey = "agent:main:discord:channel:123/thread"
    let chatId = IntentID.scoped(home.id, colonKey)
    check(IntentID.parse(chatId)?.gatewayId == home.id && IntentID.parse(chatId)?.local == colonKey,
          "chat id round-trips a key with ':' and '/'")
    check(IntentID.parse(IntentID.scoped(home.id, "research"))?.local == "research", "agent id round-trips")
    check(IntentID.parse("nope") == nil && IntentID.parse("not-a-uuid/main") == nil && IntentID.parse("\(home.id.uuidString)/") == nil,
          "malformed ids rejected")
    check(IntentGateway(work).host == "work.tail1234.ts.net" && IntentGateway(work).entityID == work.id.uuidString,
          "gateway entity: id is the profile UUID, subtitle the host")

    // Default gateway
    check(IntentService.defaultGateway([], selected: nil) == nil, "no gateways → no default")
    check(IntentService.defaultGateway([home], selected: work.id)?.id == home.id, "one gateway used silently")
    check(IntentService.defaultGateway([home, work], selected: work.id)?.id == work.id, "several → the app's selected gateway")
    check(IntentService.defaultGateway([home, work], selected: UUID())?.id == home.id, "stale selection → first")
    do {
        _ = try service([]).resolveGateway(nil)
        check(false, "no gateways throws")
    } catch {
        check(error as? IntentError == .noGateways && error.localizedDescription == "Add a Gateway in Pincer first.", "no gateways error")
    }
    do {
        _ = try service([home]).resolveGateway(work.id, name: "Work")
        check(false, "removed gateway throws")
    } catch {
        check(error as? IntentError == .gatewayRemoved(name: "Work"), "removed gateway error")
    }

    // Error text
    check(IntentError.identityMissing.localizedDescription == "Open Pincer once to finish setup.", "identity error text")
    check(IntentError.awaitingPairing(gateway: "Home").localizedDescription
          == "Home needs this device approved. Run openclaw devices approve on the Gateway host.", "pairing error text")
    check(IntentError.connectFailed(gateway: "Home", message: "bad token").localizedDescription == "Can't connect to Home: bad token."
          && IntentError.connectFailed(gateway: "Home", message: "bad token.").localizedDescription == "Can't connect to Home: bad token.",
          "connect failure text ends with one full stop")
    check(IntentError.unreachable(gateway: "Home").localizedDescription == "Home isn't reachable.", "unreachable text")
    check(IntentError.replyTimeout(agent: "Claw", seconds: 60).localizedDescription == "Sent, but Claw hasn't replied within 60 seconds.",
          "reply timeout says it was sent")
    check(IntentError.notFound(name: "Trip", gateway: "Home").localizedDescription == "Trip isn't on Home anymore.", "not found text")
    check(IntentError.sendFailed("offline").localizedDescription == "Couldn't send: offline", "send failure text")
    check(IntentError.runFailed("Model overloaded").localizedDescription == "Model overloaded", "run error is the gateway's message")

    // Speech & summaries
    check(IntentService.spoken("  Hello\n\n  world  ") == "Hello world", "speech collapses whitespace")
    let long = String(repeating: "word ", count: 200)
    let spoken = IntentService.spoken(long)
    check(spoken.count <= 501 && spoken.hasSuffix("…") && !spoken.contains("wor…"), "speech cut at a word near 500 chars")
    check(IntentService.clampTimeout(1) == 5 && IntentService.clampTimeout(999) == 300 && IntentService.clampTimeout(60) == 60,
          "timeout clamped to 5–300 s")
    func chat(_ title: String) -> IntentChat {
        IntentChat(gatewayId: home.id, gatewayName: "Home", sessionKey: title, title: title, agentId: "main", agentName: "Claw")
    }
    check(IntentService.unreadSummary([]) == "No unread chats.", "no unread summary")
    check(IntentService.unreadSummary([chat("A"), chat("B"), chat("C")]) == "3 unread chats: A, B, C.", "unread summary lists titles")
    check(IntentService.unreadSummary([chat("A")]) == "1 unread chat: A.", "singular unread summary")
    check(chat("A").subtitle == "Claw · Home", "chat subtitle is agent · gateway")
    let approval = ExecApproval(json(#"{"id":"a1","request":{"command":"\#(String(repeating: "x", count: 80))"},"expiresAtMs":9999999999999}"#))!
    let expired = ExecApproval(json(#"{"id":"a2","request":{"command":"ls"},"expiresAtMs":1000}"#))!
    let open = ExecApproval(json(#"{"id":"a3","request":{"command":"ls"}}"#))!
    check(IntentService.pending([approval, expired, open]).map(\.id) == ["a1", "a3"], "expired approvals dropped")
    let summary = IntentService.approvalsSummary([IntentApproval(gatewayName: "Home", approval: approval),
                                                  IntentApproval(gatewayName: "Home", approval: open)])
    check(summary == "2 pending approvals. First: \(String(repeating: "x", count: 59))…", "approvals summary truncates to 60 (\(summary))")
    check(IntentService.approvalsSummary([]) == "No pending approvals.", "no approvals summary")

    // Unread filtering
    let rows = [
        SessionRow(json(#"{"key":"a","unread":true,"lastActivityAt":1}"#))!,
        SessionRow(json(#"{"key":"b","unread":true,"lastActivityAt":2}"#))!,
        SessionRow(json(#"{"key":"c","unread":false}"#))!,
        SessionRow(json(#"{"key":"d","unread":true,"archived":true}"#))!,
        SessionRow(json(#"{"key":"agent:main:subagent:e","unread":true,"spawnedBy":"agent:main:main"}"#))!,
    ]
    check(IntentService.unreadRows(rows).map(\.key) == ["b", "a"], "unread: not archived, not subagents, newest first")

    // Entities from ids, offline
    let offline = service([home, work])
    let agents = offline.agents(for: [IntentID.scoped(home.id, "research"), IntentID.scoped(UUID(), "main"), "garbage"])
    check(agents.map(\.agentId) == ["research"] && agents.first?.name == "Research" && agents.first?.subtitle == "Home",
          "agent ids parsed offline; removed gateways dropped")
    let chats = offline.chats(for: [chatId, "\(UUID().uuidString)/agent:main:main"])
    check(chats.map(\.sessionKey) == [colonKey] && chats.first?.gatewayId == home.id, "chat ids parsed offline")
    check(service([home]).agents(for: [IntentID.scoped(home.id, "main")]).first?.subtitle == nil, "one gateway: no gateway subtitle")
    let liveTargets = GatewayTargets(agents: [AgentSummary(id: "main", name: "Claw", emoji: "🦞")], defaultAgentId: "main",
                                     sessions: [SessionRow(json(#"{"key":"agent:main:main","label":"Main"}"#))!])
    let liveService = service([home], connector: FakeIntentConnector(live: [home.id: liveTargets]))
    check(liveService.agents(for: [IntentID.scoped(home.id, "main"), IntentID.scoped(home.id, "gone")]).map(\.title) == ["🦞 Claw"],
          "live agents resolve names and drop removed agents")
    check(liveService.chats(for: [IntentID.scoped(home.id, "agent:main:main"), IntentID.scoped(home.id, "agent:main:gone")]).map(\.title)
          == ["Claw"], "live chats drop removed chats; a main chat is named after its agent")

    // Suggestions and search, with a name cache for offline display afterwards
    let suggesting = service([home], connector: FakeIntentConnector(connection: scriptedGateway()))
    let suggested = await suggesting.suggestedAgents()
    check(suggested.map(\.title) == ["🦞 Claw", "Scout"], "suggested agents from a one-shot fetch")
    let foundAgents = await suggesting.agents(matching: "sco")
    check(foundAgents.map(\.agentId) == ["research"], "agent search is case-insensitive")
    let foundChats = await suggesting.chats(matching: "TRIP")
    check(foundChats.map(\.title) == ["Trip"], "chat search is case-insensitive")
    let suggestedChats = await suggesting.suggestedChats()
    check(!suggestedChats.contains { $0.title == "Helper" || $0.title == "Old" }, "suggested chats skip helpers and archived chats")
    check(service([home]).agents(for: [IntentID.scoped(home.id, "main")]).first?.title == "🦞 Claw", "names remembered for offline display")
    let unreachable = service([home], connector: FakeIntentConnector(failures: [home.id: .unreachable(gateway: "Home")]))
    let none = await unreachable.suggestedAgents()
    check(none.isEmpty, "suggestions are empty when the gateway can't be reached")
    let slow = FakeIntentConnection()
    slow.responders["agents.list"] = { _ in
        try await Task.sleep(for: .seconds(3))
        return [:]
    }
    let bounded = service([home], connector: FakeIntentConnector(connection: slow))
    bounded.suggestionTimeout = 0.3
    let started = Date()
    let boundedAgents = await bounded.suggestedAgents()
    check(boundedAgents.isEmpty && Date().timeIntervalSince(started) < 2, "suggestions are time-bounded")

    // Ask: final arrives before the chat.send response
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { [weak connection] params in
            let key = params["sessionKey"]?.string ?? ""
            connection?.chatEvent(runId: "run-1", sessionKey: key, state: "delta", extra: ["deltaText": "Hi"])
            connection?.chatEvent(runId: "run-other", sessionKey: key, state: "final",
                                  extra: ["message": json(#"{"role":"assistant","content":"not mine"}"#)])
            connection?.chatEvent(runId: "run-1", sessionKey: "agent:main:elsewhere", state: "final",
                                  extra: ["message": json(#"{"role":"assistant","content":"other chat"}"#)])
            connection?.chatEvent(runId: "run-1", sessionKey: key, state: "final",
                                  extra: ["message": json(#"{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Pong"}]}"#)])
            return ["runId": "run-1", "status": "started"]
        }
        let asking = service([home], connector: FakeIntentConnector(connection: connection))
        let result = try await asking.ask("ping", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 5)
        check(result.text == "Pong" && result.agentName == "Claw", "reply buffered when final precedes the send response")
        let send = connection.requests.first { $0.method == "chat.send" }
        check(send?.params["sessionKey"]?.string == "agent:main:main", "asks the default agent's main chat")
        check(connection.observerCount == 0 && connection.closed, "listener removed and connection closed")
    } catch {
        check(false, "ask with early final (\(error.localizedDescription))")
    }

    // Ask: agent without a main chat gets a new chat; final after the response; history fallback
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { [weak connection] params in
            let key = params["sessionKey"]?.string ?? ""
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                connection?.chatEvent(runId: "run-2", sessionKey: key, state: "final")
            }
            return ["runId": "run-2"]
        }
        connection.responders["chat.history"] = { _ in
            json(#"{"messages":[{"role":"user","content":"q"},{"role":"assistant","content":"From history"},{"role":"toolResult","content":"x"}]}"#)
        }
        let asking = service([home], connector: FakeIntentConnector(connection: connection))
        let result = try await asking.ask("q", agentId: "research", gatewayId: home.id, waitForReply: true, timeoutSeconds: 5)
        check(connection.requests.contains { $0.method == "sessions.create" && $0.params["agentId"]?.string == "research" },
              "no main chat → sessions.create")
        check(result.chat.sessionKey == "agent:research:dashboard:new" && result.agentName == "Scout", "sent to the new chat")
        check(result.text == "From history", "final without text falls back to chat.history")
    } catch {
        check(false, "ask research (\(error.localizedDescription))")
    }

    // Ask: timeout, run error, not waiting, unknown agent
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { _ in ["runId": "run-3"] }
        let asking = service([home], connector: FakeIntentConnector(connection: connection))
        do {
            _ = try await asking.ask("q", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 1)
            check(false, "timeout throws")
        } catch {
            check(error as? IntentError == .replyTimeout(agent: "Claw", seconds: 5), "reply timeout after the (clamped) wait")
            check(connection.requests.contains { $0.method == "chat.send" }, "message was delivered before the timeout")
        }
        let quick = try await asking.ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 60)
        check(quick.text.isEmpty && connection.observerCount == 0, "waitForReply=false returns right after sending")
        do {
            _ = try await asking.ask("q", agentId: "ghost", agentName: "Ghost", gatewayId: nil, waitForReply: false, timeoutSeconds: 60)
            check(false, "unknown agent throws")
        } catch {
            check(error as? IntentError == .notFound(name: "Ghost", gateway: "Home"), "unknown agent → not found")
        }
        connection.responders["chat.send"] = { [weak connection] params in
            connection?.chatEvent(runId: "run-4", sessionKey: params["sessionKey"]?.string ?? "", state: "error",
                                  extra: ["errorMessage": "Model overloaded"])
            return ["runId": "run-4"]
        }
        do {
            _ = try await asking.ask("q", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 5)
            check(false, "run error throws")
        } catch {
            check(error as? IntentError == .runFailed("Model overloaded"), "run error → gateway's message")
        }
        connection.responders["chat.send"] = { _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "busy", details: nil) }
        do {
            _ = try await asking.ask("q", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 5)
            check(false, "send failure throws")
        } catch {
            check(error.localizedDescription.hasPrefix("Couldn't send: busy"), "send failure → Couldn't send (\(error.localizedDescription))")
        }
    } catch {
        check(false, "ask failures (\(error.localizedDescription))")
    }

    // Connection failures and setup
    for failure in [IntentError.awaitingPairing(gateway: "Home"), .connectFailed(gateway: "Home", message: "nope"), .unreachable(gateway: "Home")] {
        let failing = service([home], connector: FakeIntentConnector(failures: [home.id: failure]))
        do {
            _ = try await failing.ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 60)
            check(false, "connect failure throws")
        } catch {
            check(error as? IntentError == failure, "connect failure surfaces: \(failure.localizedDescription)")
        }
    }
    do {
        _ = try await service([home], identity: false, connector: FakeIntentConnector(connection: scriptedGateway()))
            .unreadChats(gatewayId: nil)
        check(false, "missing identity throws")
    } catch {
        check(error as? IntentError == .identityMissing, "missing identity → open Pincer once")
    }

    // Send, start, unread, approvals
    do {
        let connection = scriptedGateway()
        connection.responders["chat.send"] = { params in
            if params["sessionKey"]?.string == "agent:main:gone" {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown session", details: nil)
            }
            return ["runId": "r"]
        }
        connection.responders["exec.approval.list"] = { _ in
            json(#"{"approvals":[{"id":"x","request":{"command":"rm -rf ./build"},"expiresAtMs":9999999999999},{"id":"y","request":{"command":"old"},"expiresAtMs":1}]}"#)
        }
        let acting = service([home, work], selected: work.id,
                             connector: FakeIntentConnector(connection: connection, failures: [work.id: .unreachable(gateway: "Work")]))
        try await acting.send("hello", to: chat("agent:main:main"))
        check(connection.requests.last?.params["message"]?.string == "hello", "send to chat")
        do {
            try await acting.send("hello", to: IntentChat(gatewayId: home.id, gatewayName: "Home", sessionKey: "agent:main:gone",
                                                         title: "Gone", agentId: "main", agentName: "Claw"))
            check(false, "send to a deleted chat throws")
        } catch {
            check(error as? IntentError == .notFound(name: "Gone", gateway: "Home"), "deleted chat → not found")
        }
        let started = try await acting.startChat(agentId: "research", agentName: "Scout", gatewayId: home.id, message: "first")
        check(started.sessionKey == "agent:research:dashboard:new" && started.title == "New session", "start chat returns the new chat")
        check(connection.requests.last?.method == "chat.send" && connection.requests.last?.params["message"]?.string == "first",
              "start chat sends the first message")
        let unread = try await acting.unreadChats(gatewayId: nil)
        check(unread.map(\.title) == ["Trip", "Claw"], "unread across gateways skips the unreachable one (\(unread.map(\.title)))")
        do {
            _ = try await acting.unreadChats(gatewayId: work.id)
            check(false, "unread on an unreachable gateway throws")
        } catch {
            check(error as? IntentError == .unreachable(gateway: "Work"), "a chosen gateway's failure surfaces")
        }
        let pending = try await acting.pendingApprovals(gatewayId: home.id)
        check(pending.map(\.approval.id) == ["x"], "exec.approval.list without expired approvals")
    } catch {
        check(false, "send/start/unread/approvals (\(error.localizedDescription))")
    }

    await runIntentEdgeChecks(labels: labels, home: home, work: work)
}

/// Every Shortcut against the built-in demo ("Try the Demo" / App Review), over the one-shot path
/// and through the app's own demo store.
@MainActor
func runDemoIntents() async {
    let (labels, name) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let demo = GatewayProfile.demo()
    // As on a fresh install: no paired identity, only the demo saved.
    let service = IntentService(profiles: [demo], hasIdentity: false, selectedGatewayId: nil,
                                connector: GatewayIntentConnector(identity: { nil }), labels: labels)
    do {
        let result = try await service.ask("Hello from Shortcuts", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 60)
        check(!result.text.isEmpty && result.agentName == "Claw" && result.chat.sessionKey == "agent:main:main",
              "demo Ask waits for the reply (\(result.text.count) chars)")
        check(!IntentService.spoken(result.text).isEmpty, "demo reply is speakable")
        let quick = try await service.ask("No need to wait", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 60)
        check(quick.text.isEmpty && quick.agentName == "Claw", "demo Ask without waiting")
        let scout = try await service.ask("Any new papers?", agentId: "research", agentName: "Scout", gatewayId: demo.id,
                                          waitForReply: true, timeoutSeconds: 60)
        check(!scout.text.isEmpty && scout.chat.sessionKey == "agent:research:main" && scout.agentName == "Scout",
              "demo Ask a chosen agent")
    } catch {
        check(false, "demo Ask (\(error.localizedDescription))")
    }

    let agents = await service.suggestedAgents()
    check(agents.map(\.title) == ["🦞 Claw", "🔭 Scout", "🛠️ Forge"] && agents.allSatisfy { $0.subtitle == nil },
          "demo agents suggested (\(agents.map(\.title)))")
    let chats = await service.suggestedChats()
    check(chats.contains { $0.title == "home-lab" } && chats.contains { $0.title == "Paper digest" }
          && !chats.contains { $0.sessionKey.contains(":subagent:") }, "demo chats suggested (\(chats.map(\.title)))")
    check(!chats.contains { $0.title == "Main" } && ["Claw", "Scout", "Forge"].allSatisfy { name in chats.contains { $0.title == name } },
          "demo main chats named after their agents")
    let foundAgents = await service.agents(matching: "forge")
    check(foundAgents.map(\.agentId) == ["coder"], "demo agent search")
    let foundChats = await service.chats(matching: "PAPER")
    check(foundChats.map(\.title) == ["Paper digest"] && foundChats.first?.agentName == "Scout", "demo chat search")
    check(service.agents(for: agents.map(\.entityID)).map(\.title) == agents.map(\.title)
          && service.chats(for: chats.map(\.entityID)).map(\.title) == chats.map(\.title), "demo entities resolve offline from ids")

    do {
        let unread = try await service.unreadChats(gatewayId: nil)
        check(unread.count >= 1 && unread.allSatisfy { $0.gatewayId == demo.id && !$0.sessionKey.contains(":subagent:") },
              "demo unread chats (\(unread.map(\.title)))")
        check(IntentService.unreadSummary(unread).hasPrefix("\(unread.count) unread chat"), "demo unread summary: \(IntentService.unreadSummary(unread))")
        let approvals = try await service.pendingApprovals(gatewayId: nil)
        check(approvals.count >= 1 && approvals.allSatisfy { !$0.approval.isExpired() && $0.gatewayName == demo.name }
              && approvals.contains { $0.approval.command == "git push origin fix/login-timeout" },
              "demo pending approvals (\(approvals.map(\.approval.command)))")
        check(IntentService.approvalsSummary(approvals).contains("git push"), "demo approvals summary: \(IntentService.approvalsSummary(approvals))")

        guard let homeLab = chats.first(where: { $0.title == "home-lab" }) else { return check(false, "demo home-lab chat") }
        try await service.send("Status of the lab sensor?", to: homeLab)
        check(true, "demo Send to chat")
        let ghost = IntentChat(gatewayId: demo.id, gatewayName: demo.name, sessionKey: "agent:main:dashboard:nope",
                               title: "Nope", agentId: "main", agentName: "Claw")
        do {
            try await service.send("hello?", to: ghost)
            check(false, "demo send to an unknown chat throws")
        } catch {
            check(error as? IntentError == .notFound(name: "Nope", gateway: demo.name), "demo unknown chat → not found (\(error.localizedDescription))")
        }
        let started = try await service.startChat(agentId: "coder", agentName: "Forge", gatewayId: demo.id, message: "Run the tests")
        check(started.sessionKey.hasPrefix("agent:coder:") && started.agentName == "Forge" && started.gatewayId == demo.id,
              "demo Start chat via sessions.create (\(started.sessionKey))")
    } catch {
        check(false, "demo unread/approvals/send/start (\(error.localizedDescription))")
    }

    // With the app's demo store (not yet started, as when Siri launches Pincer): the Shortcut
    // starts and reuses it, so what it creates shows up in the app.
    let store = GatewayStore(profile: demo)
    let inApp = IntentService(profiles: [demo], hasIdentity: false, selectedGatewayId: nil,
                              connector: GatewayIntentConnector(liveStore: { $0 == demo.id ? store : nil }, identity: { nil }),
                              labels: labels)
    do {
        let started = try await inApp.startChat(agentId: "research", agentName: "Scout", gatewayId: demo.id, message: "Find a paper")
        check(store.state.isConnected, "Start chat starts the app's demo")
        let appSees = await waitFor("demo chat in the app") { store.sessions[started.sessionKey] != nil }
        check(appSees, "the new demo chat is in the app's list, ready to open")
        let answer = try await inApp.ask("Hello again", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 60)
        let chat = store.chat(for: answer.chat.sessionKey)
        await chat.load()
        check(!answer.text.isEmpty && chat.items.contains { $0.plainText.contains("Hello again") },
              "Ask over the app's demo shows in its chat")
        let approvals = try await inApp.pendingApprovals(gatewayId: nil)
        check(approvals.map(\.approval.id) == store.approvals.map(\.id) && !approvals.isEmpty, "approvals from the app's demo")
    } catch {
        check(false, "demo through the app's store (\(error.localizedDescription))")
    }
    store.stop()

    // Answering the seeded push finishes Forge's story, either way.
    for (decision, reply) in [("allow-once", "Pushed fix/login-timeout to origin."), ("deny", "OK, I won't push.")] {
        let app = GatewayStore(profile: demo)
        app.start()
        let ready = await waitFor("demo for \(decision)") { app.state.isConnected && !app.approvals.isEmpty }
        guard ready, let seeded = app.approvals.first(where: { $0.command == "git push origin fix/login-timeout" }) else {
            check(false, "seeded push approval for \(decision)")
            app.stop()
            continue
        }
        let forge = app.chat(for: "agent:coder:main")
        await forge.load()
        let outcome = await app.resolveApproval(seeded, decision: decision)
        let followed = await waitFor("Forge follow-up") {
            forge.items.last?.plainText == reply && app.sessions["agent:coder:main"]?.raw["lastMessagePreview"]?.string == reply
        }
        check(outcome == .resolved && followed, "\(decision) on the seeded push → Forge says \"\(reply)\"")
        let leftover = try? await IntentService(profiles: [demo], hasIdentity: false, selectedGatewayId: nil,
                                              connector: GatewayIntentConnector(liveStore: { _ in app }, identity: { nil }),
                                              labels: labels).pendingApprovals(gatewayId: nil)
        check(leftover?.isEmpty == true, "\(decision): nothing left pending for Shortcuts")
        app.stop()
    }
}

/// Ask and friends against a (mock) Gateway, as the paired device.
@MainActor
func runLiveIntents(profile: GatewayProfile, gateway: GatewayStore) async {
    let (labels, name) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let oneShot = IntentService(profiles: [profile], hasIdentity: DeviceIdentity.loadExisting() != nil, selectedGatewayId: nil,
                                connector: GatewayIntentConnector(), labels: labels)
    do {
        let result = try await oneShot.ask("Hello from Siri", agentId: "main", gatewayId: profile.id, waitForReply: true, timeoutSeconds: 60)
        check(result.text.contains("Hello from Siri"), "one-shot Ask returns the mock reply")
    } catch {
        check(false, "one-shot Ask (\(error.localizedDescription))")
    }
    let agents = await oneShot.suggestedAgents()
    check(agents.count >= 3, "one-shot agent suggestions (\(agents.count))")
    do {
        let unread = try await oneShot.unreadChats(gatewayId: nil)
        check(unread.allSatisfy { !$0.sessionKey.contains(":subagent:") }, "one-shot unread chats (\(unread.count))")
        _ = try await oneShot.pendingApprovals(gatewayId: nil)
        check(true, "one-shot pending approvals")
    } catch {
        check(false, "one-shot unread/approvals (\(error.localizedDescription))")
    }

    // Reusing the app's connected store, as when Pincer is running.
    _ = await waitFor("app connection") { gateway.state.isConnected }
    let reusing = IntentService(profiles: [profile], hasIdentity: true, selectedGatewayId: nil,
                                connector: GatewayIntentConnector(liveStore: { $0 == gateway.id ? gateway : nil }), labels: labels)
    do {
        let result = try await reusing.ask("Reuse the app", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 60)
        check(result.text.contains("Reuse the app"), "Ask over the app's live connection")
    } catch {
        check(false, "live-store Ask (\(error.localizedDescription))")
    }
    check(!reusing.agents(for: [IntentID.scoped(profile.id, "main")]).isEmpty, "live agent entity lookup")

    // Start chat via sessions.create, with a first message.
    do {
        let started = try await oneShot.startChat(agentId: "main", agentName: "Main", gatewayId: profile.id, message: "Start from Shortcuts")
        check(started.sessionKey.hasPrefix("agent:main:dashboard:") && started.gatewayId == profile.id, "one-shot start chat (\(started.sessionKey))")
        let appSees = await waitFor("started chat in the app") { gateway.sessions[started.sessionKey] != nil }
        check(appSees, "the new chat reaches the app's session list")
        try await oneShot.send("Follow-up from Shortcuts", to: started)
        check(true, "one-shot send to the started chat")
    } catch {
        check(false, "one-shot start chat (\(error.localizedDescription))")
    }

    // A chat the Gateway doesn't know: the send fails with "unknown session", reported as not found.
    let ghost = IntentChat(gatewayId: profile.id, gatewayName: profile.name, sessionKey: "agent:main:dashboard:does-not-exist",
                           title: "Ghost chat", agentId: "main", agentName: "Main")
    for (label, service) in [("one-shot", oneShot), ("live store", reusing)] {
        do {
            try await service.send("hello?", to: ghost)
            check(false, "\(label): send to an unknown session throws")
        } catch {
            check(error as? IntentError == .notFound(name: "Ghost chat", gateway: profile.name),
                  "\(label): unknown session → not found (\(error.localizedDescription))")
        }
    }

    // The one-shot connection is stopped once closed.
    do {
        let connection = try await GatewayIntentConnector().connect(profile, timeout: 10)
        let before = try? await connection.request("agents.list", [:], timeout: 5)
        await connection.close()
        let after = try? await connection.request("agents.list", [:], timeout: 3)
        check(before?["agents"] != nil && after == nil, "one-shot connection answers, then is stopped by close()")
    } catch {
        check(false, "one-shot connect (\(error.localizedDescription))")
    }

    // Two saved gateways (both the mock): chats come back tagged with each.
    let second = GatewayProfile(name: "Mock B", url: profile.url, authMode: .token)
    second.secret = profile.secret
    let pair = IntentService(profiles: [profile, second], hasIdentity: true, selectedGatewayId: second.id,
                             connector: GatewayIntentConnector(), labels: labels)
    let pairChats = await pair.suggestedChats()
    let fromFirst = pairChats.filter { $0.gatewayId == profile.id }
    let fromSecond = pairChats.filter { $0.gatewayId == second.id }
    check(!fromFirst.isEmpty && fromFirst.count == fromSecond.count
          && fromFirst.allSatisfy { $0.gatewayName == profile.name } && fromSecond.allSatisfy { $0.gatewayName == "Mock B" }
          && Set(pairChats.map(\.entityID)).count == pairChats.count,
          "chats from both gateways, tagged correctly (\(fromFirst.count) + \(fromSecond.count))")
    do {
        let unread = try await pair.unreadChats(gatewayId: nil)
        let firstKeys = unread.filter { $0.gatewayId == profile.id }.map(\.sessionKey)
        let secondKeys = unread.filter { $0.gatewayId == second.id }.map(\.sessionKey)
        check(Set(firstKeys) == Set(secondKeys), "unread chats from both gateways (\(firstKeys.count) + \(secondKeys.count))")
        let asked = try await pair.ask("Default gateway", agentId: nil, gatewayId: nil, waitForReply: true, timeoutSeconds: 60)
        check(asked.chat.gatewayId == second.id && asked.text.contains("Default gateway"), "ask with no gateway uses the selected one")
    } catch {
        check(false, "two gateways (\(error.localizedDescription))")
    }
    second.secret = nil

    // A bad token: the one-shot connection fails instead of retrying.
    let wrong = GatewayProfile(name: "Wrong", url: profile.url, authMode: .token)
    wrong.secret = "not-the-token"
    let rejected = IntentService(profiles: [wrong], hasIdentity: true, selectedGatewayId: nil,
                                 connector: GatewayIntentConnector(), labels: labels)
    let started = Date()
    do {
        _ = try await rejected.ask("q", agentId: nil, gatewayId: nil, waitForReply: false, timeoutSeconds: 5)
        check(false, "bad token throws")
    } catch {
        let failed = if case .connectFailed(gateway: "Wrong", _) = error as? IntentError { true } else { false }
        check(failed && error.localizedDescription.hasPrefix("Can't connect to Wrong: ") && Date().timeIntervalSince(started) < 8,
              "bad token → connect failed (\(error.localizedDescription))")
        check(!error.localizedDescription.contains("["), "bad token: no Gateway code read aloud")
    }
    let noSuggestions = await rejected.suggestedAgents()
    check(noSuggestions.isEmpty, "bad token → no suggestions")
    wrong.secret = nil
}
