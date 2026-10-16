import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

// #981: Stop aborts the whole session with `sessions.abort`.

/// Raw RPC needs the internal connection, so release builds of the checks can't issue it.
@MainActor
private func rpc(_ gateway: GatewayStore, _ method: String, _ params: JSONValue) async throws -> JSONValue {
    #if DEBUG
    return try await gateway.connection.request(method, params)
    #else
    throw NSError(domain: "PincerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "raw RPC needs a debug build"])
    #endif
}

private let refactorKey = "agent:coder:dashboard:refactor"

@MainActor
func runSessionAbortOfflineChecks() {
    check(SessionKey.isGlobal("global", scopeIsGlobal: false) && SessionKey.isGlobal("GLOBAL", scopeIsGlobal: false),
          "`global` is always the global session")
    check(!SessionKey.isGlobal("main", scopeIsGlobal: false) && !SessionKey.isGlobal("agent:main:main", scopeIsGlobal: false),
          "a main alias is per-agent unless the Gateway scope is global")
    check(SessionKey.isGlobal("main", scopeIsGlobal: true) && SessionKey.isGlobal("agent:research:main", scopeIsGlobal: true),
          "a main alias is the global session under scope global")
    check(!SessionKey.isGlobal("agent:coder:dashboard:refactor", scopeIsGlobal: true), "a dashboard chat is never global")
}

@MainActor
func runDemoSessionAbortChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    let connected = await waitFor("demo for session abort") { gateway.state.isConnected && gateway.sessions[refactorKey] != nil }
    check(connected, "demo connected")
    defer { gateway.stop() }
    guard connected else { return }
    check(gateway.advertises("sessions.abort"), "the demo advertises sessions.abort")

    let running = gateway.sessions[refactorKey]
    check(running?.hasActiveRun == true, "the seeded refactor chat is running")
    let chat = gateway.chat(for: refactorKey)
    let stopped = await chat.abortSession()
    check(stopped && chat.errorMessage == nil, "abortSession succeeds (\(chat.errorMessage ?? "ok"))")
    let cleared = await waitFor("seeded run stopped by sessions.abort", timeout: 5) { gateway.sessions[refactorKey]?.hasActiveRun == false }
    check(cleared, "sessions.abort clears hasActiveRun on the seeded run")

    let again = await chat.abortSession()
    check(again && chat.errorMessage == nil, "stopping an idle session is a successful no-active-run")

    let raw = try? await rpc(gateway, "sessions.abort", ["key": .string(refactorKey), "clearQueued": true])
    check(raw?["ok"]?.bool == true && raw?["status"]?.text == "no-active-run" && raw?["abortedRunId"]?.isNull != false,
          "idle result shape (\(String(describing: raw)))")

    // Key-only abort of a parent also stops its running helper.
    let parent = demoSubagentParent
    let helper = demoSubagentKeys.running
    let helperRunning = await waitFor("demo helper running") { gateway.subagentTree(rootKey: parent).node(helper)?.status == .running }
    check(helperRunning, "the demo helper is running before the stop")
    let parentStopped = await gateway.chat(for: parent).abortSession()
    check(parentStopped, "abortSession on the parent succeeds")
    let helperStopped = await waitFor("demo helper aborted by the parent stop") {
        gateway.subagentTree(rootKey: parent).node(helper)?.status == .aborted
            && gateway.sessions[helper]?.hasActiveRun != true
    }
    check(helperStopped, "stopping the parent session also stops its running subagent (\(String(describing: gateway.subagentTree(rootKey: parent).node(helper)?.status)))")

    // Upstream errors.
    do {
        _ = try await rpc(gateway, "sessions.abort", ["key": "agent:main:dashboard:nope"])
        check(false, "an unknown session key is rejected")
    } catch {
        check(error.localizedDescription.contains("session target is unavailable"), "unknown key → session target is unavailable (\(error.localizedDescription))")
    }
    do {
        _ = try await rpc(gateway, "sessions.abort", ["key": .string(parent), "runId": "not-a-run"])
        check(false, "a foreign runId is rejected")
    } catch {
        check(error.localizedDescription.contains("runId does not match session"), "foreign runId → runId does not match session (\(error.localizedDescription))")
    }
    let missing = gateway.chat(for: "agent:main:dashboard:nope")
    let failed = await missing.abortSession()
    check(!failed && missing.errorMessage?.hasPrefix("Couldn’t stop") == true, "a rejected stop reports Couldn’t stop (\(missing.errorMessage ?? "nil"))")
}

@MainActor
func runLiveSessionAbortChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock session abort", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor("mock for session abort", timeout: 25) { gateway.state.isConnected && gateway.hello != nil && !gateway.sessions.isEmpty }
    check(connected, "mock connected")
    defer { gateway.stop() }
    guard connected else { return }
    check(gateway.advertises("sessions.abort"), "the mock advertises sessions.abort")

    do {
        _ = try await rpc(gateway, "sessions.abort", ["key": "agent:main:dashboard:nope"])
        check(false, "an unknown session key is rejected")
    } catch {
        check(error.localizedDescription.contains("session target is unavailable"), "unknown key → session target is unavailable (\(error.localizedDescription))")
    }

    // Fresh chats, so the seeded runs other sections rely on stay untouched. Each starts a reply to stop.
    func startRun(_ name: String) async -> ChatStore? {
        guard let key = await gateway.createSession(agentId: "main", label: "Abort \(name)", select: false) else {
            check(false, "a chat to stop (\(name))")
            return nil
        }
        let chat = gateway.chat(for: key)
        await chat.load()
        let outcome = await chat.send("Stop test, use a tool \(name)")
        let running = await waitFor("run \(name) in flight", timeout: 10, every: 20) { chat.isRunning }
        check(running, "a reply is in flight (\(name)): \(outcome), \(chat.errorMessage ?? "no error"), entries \(chat.entries.count)")
        return running ? chat : nil
    }

    if let chat = await startRun("session") {
        let runId = chat.live?.runId
        let stopped = await chat.abortSession()
        check(stopped && chat.errorMessage == nil, "abortSession succeeds (\(chat.errorMessage ?? "ok"))")
        let ended = await waitFor("session stop ends the run", timeout: 5) { !chat.isRunning }
        check(ended, "sessions.abort ends the live run (\(runId ?? "nil"))")
        let row = await waitFor("row clears", timeout: 5) { gateway.sessions[chat.sessionKey]?.hasActiveRun != true }
        check(row, "the session row no longer reports an active run")
        let idle = await chat.abortSession()
        check(idle && chat.errorMessage == nil, "abortSession on an idle session succeeds (\(chat.errorMessage ?? "ok"))")
    }

    if let chat = await startRun("raw") {
        let runId = chat.live?.runId
        let result = try? await rpc(gateway, "sessions.abort", ["key": .string(chat.sessionKey), "clearQueued": true])
        check(result?["ok"]?.bool == true && result?["status"]?.text == "aborted" && result?["abortedRunId"]?.text?.hasPrefix("run_") == true,
              "aborted result shape (\(String(describing: result)), run \(runId ?? "nil"))")
        let ended = await waitFor("raw stop ends the run", timeout: 5) { !chat.isRunning }
        check(ended, "the aborted event ends the live run")
        let idle = try? await rpc(gateway, "sessions.abort", ["key": .string(chat.sessionKey), "clearQueued": true])
        check(idle?["ok"]?.bool == true && idle?["status"]?.text == "no-active-run" && idle?["abortedRunId"]?.isNull != false,
              "no-active-run result shape (\(String(describing: idle)))")
        do {
            _ = try await rpc(gateway, "sessions.abort", ["key": .string(chat.sessionKey), "runId": "not-a-run"])
            check(false, "a foreign runId is rejected")
        } catch {
            check(error.localizedDescription.contains("runId does not match session"), "foreign runId → runId does not match session (\(error.localizedDescription))")
        }
    }

    if let chat = await startRun("button") {
        _ = await waitFor("run id known", timeout: 5, every: 20) { chat.live?.runId != nil }
        await chat.abort()
        let ended = await waitFor("Stop ends the run", timeout: 5) { !chat.isRunning }
        check(ended, "Stop with a live run id ends the run")
    }

    let missing = gateway.chat(for: "agent:main:dashboard:nope")
    let failed = await missing.abortSession()
    check(!failed && missing.errorMessage?.hasPrefix("Couldn’t stop") == true, "a rejected stop reports Couldn’t stop (\(missing.errorMessage ?? "nil"))")
}
