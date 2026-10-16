import Foundation
import PincerKit

// #981: Stop aborts the whole session with `sessions.abort`.

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

    let raw = try? await gateway.connection.request("sessions.abort", ["key": .string(refactorKey), "clearQueued": true])
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
        _ = try await gateway.connection.request("sessions.abort", ["key": "agent:main:dashboard:nope"])
        check(false, "an unknown session key is rejected")
    } catch {
        check(error.localizedDescription.contains("session target is unavailable"), "unknown key → session target is unavailable (\(error.localizedDescription))")
    }
    do {
        _ = try await gateway.connection.request("sessions.abort", ["key": .string(parent), "runId": "not-a-run"])
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
    let connected = await waitFor("mock for session abort", timeout: 25) { gateway.state.isConnected && gateway.sessions[refactorKey] != nil }
    check(connected, "mock connected")
    defer { gateway.stop() }
    guard connected else { return }
    check(gateway.advertises("sessions.abort"), "the mock advertises sessions.abort")

    check(gateway.sessions[refactorKey]?.hasActiveRun == true, "the seeded refactor chat is running")
    // The seeded run id comes from the row, so a stale constant can't hide a wrong abortedRunId.
    let runId = gateway.sessions[refactorKey]?.raw["activeRunIds"]?.array?.first?.text

    do {
        _ = try await gateway.connection.request("sessions.abort", ["key": .string(refactorKey), "runId": "not-a-run"])
        check(false, "a foreign runId is rejected")
    } catch {
        check(error.localizedDescription.contains("runId does not match session"), "foreign runId → runId does not match session (\(error.localizedDescription))")
    }
    do {
        _ = try await gateway.connection.request("sessions.abort", ["key": "agent:main:dashboard:nope"])
        check(false, "an unknown session key is rejected")
    } catch {
        check(error.localizedDescription.contains("session target is unavailable"), "unknown key → session target is unavailable (\(error.localizedDescription))")
    }

    let result = try? await gateway.connection.request("sessions.abort", ["key": .string(refactorKey), "clearQueued": true])
    check(result?["ok"]?.bool == true && result?["status"]?.text == "aborted" && result?["abortedRunId"]?.text == runId,
          "aborted result shape (\(String(describing: result)), run \(runId ?? "nil"))")
    let cleared = await waitFor("seeded run stopped", timeout: 5) { gateway.sessions[refactorKey]?.hasActiveRun == false }
    check(cleared, "sessions.abort clears hasActiveRun on the seeded run")

    let idle = try? await gateway.connection.request("sessions.abort", ["key": .string(refactorKey), "clearQueued": true])
    check(idle?["ok"]?.bool == true && idle?["status"]?.text == "no-active-run" && idle?["abortedRunId"]?.isNull != false,
          "no-active-run result shape (\(String(describing: idle)))")
    let chat = gateway.chat(for: refactorKey)
    let again = await chat.abortSession()
    check(again && chat.errorMessage == nil, "abortSession on an idle session succeeds (\(chat.errorMessage ?? "ok"))")

    // Key-only abort of the parent cascades to its running helper.
    let parent = seededSubagentParent
    let helper = seededSubagentKeys.running
    let helperRunning = await waitFor("mock helper running") { gateway.subagentTree(rootKey: parent).node(helper)?.status == .running }
    check(helperRunning, "the mock helper is running before the stop")
    let parentStopped = await gateway.chat(for: parent).abortSession()
    check(parentStopped, "abortSession on the parent succeeds")
    let helperStopped = await waitFor("mock helper aborted by the parent stop") {
        gateway.subagentTree(rootKey: parent).node(helper)?.status == .aborted && gateway.sessions[helper]?.hasActiveRun != true
    }
    check(helperStopped, "stopping the parent session also stops its running subagent (\(String(describing: gateway.subagentTree(rootKey: parent).node(helper)?.status)))")

    let missing = gateway.chat(for: "agent:main:dashboard:nope")
    let failed = await missing.abortSession()
    check(!failed && missing.errorMessage?.hasPrefix("Couldn’t stop") == true, "a rejected stop reports Couldn’t stop (\(missing.errorMessage ?? "nil"))")
}
