import Foundation
import PincerKit

// #202: reconnect / bootstrap behaviour against the mock (uses its mock.control RPC for counters,
// delayed responses, mid-flight events and drops). Run alone with:
//   swift run PincerChecks --live-reconnect ws://127.0.0.1:PORT dev-token   (fresh mock)

/// A second, raw connection to the mock. Its own requests are never counted by the mock.
@MainActor
final class MockControl {
    private let connection: GatewayConnection
    private let ready = Scripted(false)

    struct Stats {
        var total: [String: Int]
        var connections: [[String]]

        func count(_ method: String) -> Int { self.total[method] ?? 0 }
        func count(_ method: String, onConnection index: Int) -> Int {
            self.connections.indices.contains(index) ? self.connections[index].filter { $0 == method }.count : 0
        }
    }

    init(profile: GatewayProfile) { self.connection = GatewayConnection(profile: profile) }

    func start() async -> Bool {
        let ready = self.ready
        await self.connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
            if state.isConnected { Task { @MainActor in ready.value = true } }
        })
        await self.connection.start()
        return await waitFor("control connection", timeout: 25) { ready.value }
    }

    func stop() async { await self.connection.stop() }

    @discardableResult
    func call(_ action: String, _ extra: [String: JSONValue] = [:]) async -> JSONValue? {
        var params = extra
        params["action"] = .string(action)
        return try? await self.connection.request("mock.control", .object(params))
    }

    func stats() async -> Stats {
        let result = await self.call("stats")
        let total = (result?["total"]?.object ?? [:]).compactMapValues { $0.int }
        let connections = (result?["connections"]?.array ?? []).map { ($0["log"]?.array ?? []).compactMap { $0.string } }
        return Stats(total: total, connections: connections)
    }

    func setDelays(_ delays: [String: Int]) async {
        await self.call("setDelay", ["delays": .object(delays.mapValues { .number(Double($0)) })])
    }
}

private let probeMethods = ["users.prefs.get", "sessions.subscribe", "sessions.messages.subscribe", "sessions.messages.unsubscribe",
                            "sessions.list", "chat.history", "health", "agents.list", "sessions.groups.list"]

private func summary(_ stats: MockControl.Stats) -> String {
    let named = probeMethods.map { "\($0)=\(stats.count($0))" }.joined(separator: " ")
    let total = stats.total.values.reduce(0, +)
    return "\(named) total=\(total)"
}

@MainActor
private func connectedStore(url: String, token: String) async -> GatewayStore? {
    let profile = GatewayProfile(name: "Reconnect", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let ok = await waitFor("connected and bootstrapped", timeout: 30) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    guard ok else { gateway.stop(); return nil }
    return gateway
}

/// Waits for the socket to drop, come back and the store to be bootstrapped again, then for traffic to go quiet.
@MainActor
private func settleAfterReconnect(_ gateway: GatewayStore, control: MockControl, minConnections: Int = 1) async -> Bool {
    // The new connection shows up in the mock's stats once it sends its first request.
    var seen = false
    let waitUntil = Date().addingTimeInterval(40)
    while Date() < waitUntil {
        if await control.stats().connections.count >= minConnections { seen = true; break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    var back = false
    if seen { back = await waitFor("reconnect", timeout: 40) { gateway.state.isConnected && !gateway.sessions.isEmpty } }
    var last = await control.stats().total.values.reduce(0, +), since = Date()
    while Date().timeIntervalSince(since) < 2, Date().timeIntervalSince(since) < 15 {
        try? await Task.sleep(for: .milliseconds(250))
        let now = await control.stats().total.values.reduce(0, +)
        if now != last { last = now; since = Date() }
    }
    return back
}

@MainActor
func runLiveReconnect(url: String, token: String) async {
    let profile = GatewayProfile(name: "Reconnect control", url: url, authMode: .token)
    profile.secret = token
    let control = MockControl(profile: profile)
    let controlReady = await control.start()
    guard controlReady else { check(false, "control connection to the mock"); return }
    defer { Task { await control.stop() } }

    await runRPCCountProbe(url: url, token: token, control: control)
    await runBootstrapRace(url: url, token: token, control: control)
    await runOverlappingReconnects(url: url, token: token, control: control)
    await runRequestCancellation(profile: profile, control: control)
}

// MARK: (c) RPC counts per launch and per reconnect

@MainActor
private func runRPCCountProbe(url: String, token: String, control: MockControl) async {
    print("RPC counts (launch, reconnect, one run)")
    await control.call("resetStats")
    guard let gateway = await connectedStore(url: url, token: token) else { check(false, "probe store connects"); return }
    defer { gateway.stop() }
    let key = "agent:main:main"
    gateway.selectedKey = key
    let chat = gateway.chat(for: key)
    let chatLoaded = await waitFor("chat loaded") { chat.hasLoaded }
    check(chatLoaded, "selected chat loaded")
    var last = -1, since = Date()
    while Date().timeIntervalSince(since) < 2 {
        try? await Task.sleep(for: .milliseconds(250))
        let now = await control.stats().total.values.reduce(0, +)
        if now != last { last = now; since = Date() }
    }
    let launch = await control.stats()
    print("  launch:    \(summary(launch))")
    check(launch.count("users.prefs.get") <= 1, "launch: users.prefs.get ≤ 1 (\(launch.count("users.prefs.get")))")
    check(launch.count("sessions.messages.subscribe") <= 1, "launch: sessions.messages.subscribe ≤ 1 for one open chat (\(launch.count("sessions.messages.subscribe")))")
    check(launch.count("sessions.subscribe") == 1, "launch: one sessions.subscribe (\(launch.count("sessions.subscribe")))")

    await control.call("resetStats")
    await control.call("drop")
    let reconnected = await settleAfterReconnect(gateway, control: control)
    check(reconnected, "reconnected after a drop")
    let reconnect = await control.stats()
    print("  reconnect: \(summary(reconnect))")
    check(reconnect.count("users.prefs.get") <= 1, "reconnect: users.prefs.get ≤ 1 (\(reconnect.count("users.prefs.get")))")
    check(reconnect.count("sessions.messages.subscribe") <= 1, "reconnect: sessions.messages.subscribe ≤ 1 for one open chat (\(reconnect.count("sessions.messages.subscribe")))")
    check(reconnect.count("sessions.subscribe") == 1, "reconnect: one sessions.subscribe (\(reconnect.count("sessions.subscribe")))")
    check(reconnect.count("chat.history") <= 1, "reconnect: chat.history ≤ 1 for one open chat (\(reconnect.count("chat.history")))")

    await control.call("resetStats")
    await chat.send("reconnect probe: say hi")
    _ = await waitFor("run started", timeout: 10) { chat.isRunning || chat.items.count > 2 }
    _ = await waitFor("run finished", timeout: 30) { !chat.isRunning && chat.live == nil }
    var lastRun = -1
    var runSince = Date()
    while Date().timeIntervalSince(runSince) < 2 {
        try? await Task.sleep(for: .milliseconds(250))
        let now = await control.stats().total.values.reduce(0, +)
        if now != lastRun { lastRun = now; runSince = Date() }
    }
    let run = await control.stats()
    print("  one run:   \(summary(run))")
    check(run.count("chat.history") <= 1, "one finished run: chat.history ≤ 1 (\(run.count("chat.history")))")
    check(run.count("sessions.messages.subscribe") == 0, "one finished run: no re-subscribe (\(run.count("sessions.messages.subscribe")))")
}

// MARK: (a) bootstrap race

@MainActor
private func waitForSubscribe(_ control: MockControl, connection index: Int? = nil) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        let stats = await control.stats()
        if stats.count("sessions.subscribe") > 0 { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@MainActor
private func runBootstrapRace(url: String, token: String, control: MockControl) async {
    print("Bootstrap race: events during a delayed sessions.subscribe")
    guard let gateway = await connectedStore(url: url, token: token) else { check(false, "race store connects"); return }
    defer { gateway.stop() }
    gateway.selectedKey = "agent:main:main"
    _ = await waitFor("initial chat") { gateway.chat(for: "agent:main:main").hasLoaded }
    guard let key = gateway.sessions.keys.sorted().first(where: { $0 != "agent:main:main" }) else { check(false, "a second session"); return }

    // Baseline: how many sessions.list does a plain reconnect send?
    await control.call("resetStats")
    await control.call("drop")
    _ = await settleAfterReconnect(gateway, control: control)
    let baseline = await control.stats().count("sessions.list")

    // A row change arrives while the snapshot (taken earlier) is still in flight.
    let label = "RACE \(UUID().uuidString.prefix(6))"
    await control.setDelays(["sessions.subscribe": 900])
    await control.call("resetStats")
    await control.call("drop")
    let sawSubscribe = await waitForSubscribe(control)
    check(sawSubscribe, "delayed sessions.subscribe reached the mock")
    await control.call("patchSession", ["key": .string(key), "patch": ["label": .string(label)]])
    await control.setDelays([:])
    let back = await settleAfterReconnect(gateway, control: control)
    check(back, "bootstrap finished after the delayed subscribe")
    check(gateway.sessions[key]?.raw["label"]?.text == label,
          "row changed during the delayed subscribe survives the stale snapshot (\(gateway.sessions[key]?.raw["label"]?.text ?? "nil"))")

    // An event that only invalidates the list: exactly one trailing sessions.list on top of the baseline.
    await control.setDelays(["sessions.subscribe": 900])
    await control.call("resetStats")
    await control.call("drop")
    let sawSecond = await waitForSubscribe(control)
    check(sawSecond, "second delayed sessions.subscribe reached the mock")
    await control.call("emit", ["event": "sessions.changed", "payload": ["reason": "groups"]])
    await control.setDelays([:])
    _ = await settleAfterReconnect(gateway, control: control)
    let lists = await control.stats().count("sessions.list")
    print("  sessions.list per reconnect: baseline \(baseline), with an invalidation-only event \(lists)")
    check(lists == baseline + 1, "invalidation-only event during the subscribe → one trailing sessions.list (\(lists) vs baseline \(baseline))")
}

// MARK: (b) overlapping reconnects

@MainActor
private func runOverlappingReconnects(url: String, token: String, control: MockControl) async {
    print("Overlapping reconnects")
    guard let gateway = await connectedStore(url: url, token: token) else { check(false, "overlap store connects"); return }
    defer { gateway.stop() }
    gateway.selectedKey = "agent:main:main"
    _ = await waitFor("initial chat") { gateway.chat(for: "agent:main:main").hasLoaded }
    guard let key = gateway.sessions.keys.sorted().first(where: { $0 != "agent:main:main" }) else { check(false, "a second session"); return }

    let old = "OLD \(UUID().uuidString.prefix(6))", new = "NEW \(UUID().uuidString.prefix(6))"
    await control.call("patchSession", ["key": .string(key), "patch": ["label": .string(old)]])
    _ = await waitFor("old label") { gateway.sessions[key]?.raw["label"]?.text == old }

    await control.setDelays(["sessions.subscribe": 700, "users.prefs.get": 300])
    await control.call("resetStats")
    await control.call("drop")
    let sawFirst = await waitForSubscribe(control)
    check(sawFirst, "first bootstrap started")
    // Second drop while the first bootstrap is still in flight; the row changes in between.
    await control.call("patchSession", ["key": .string(key), "patch": ["label": .string(new)]])
    await control.call("drop")

    var history: [String?] = []
    await control.setDelays([:])
    let done = await settleAfterReconnect(gateway, control: control, minConnections: 2)
    check(done, "second bootstrap finished")
    check(gateway.sessions[key]?.raw["label"]?.text == new, "final state shows the newest row (\(gateway.sessions[key]?.raw["label"]?.text ?? "nil"))")
    for _ in 0..<40 {
        history.append(gateway.sessions[key]?.raw["label"]?.text)
        try? await Task.sleep(for: .milliseconds(50))
    }
    let firstNew = history.firstIndex(of: new)
    let staleAfterNew = firstNew.map { history[$0...].contains(old) } ?? true
    check(!staleAfterNew, "no stale publish: the old row never comes back after the new one")

    let stats = await control.stats()
    let lastConnection = stats.connections.count - 1
    print("  connections: \(stats.connections.count); last connection: subscribe=\(stats.count("sessions.subscribe", onConnection: lastConnection)) prefs=\(stats.count("users.prefs.get", onConnection: lastConnection))")
    check(stats.count("sessions.subscribe", onConnection: lastConnection) == 1, "one effective sessions.subscribe on the final connection")
    check(stats.count("users.prefs.get", onConnection: lastConnection) <= 1, "users.prefs.get ≤ 1 on the final connection")
    let staleEpochs = stats.connections.dropLast().map { $0.filter { $0 == "users.prefs.get" }.count }
    check(staleEpochs.allSatisfy { $0 <= 1 }, "superseded connections sent users.prefs.get at most once each (\(staleEpochs))")
}

// MARK: (d) request cancellation

/// A cancelled request throws right away (it doesn't wait for the delayed response or the 20 s timeout),
/// and the late response for its id is ignored: the connection keeps working.
@MainActor
private func runRequestCancellation(profile: GatewayProfile, control: MockControl) async {
    print("Request cancellation")
    let connection = GatewayConnection(profile: profile)
    let ready = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in ready.value = true } }
    })
    await connection.start()
    defer { Task { await connection.stop() } }
    let up = await waitFor("cancellation connection", timeout: 25) { ready.value }
    guard up else { check(false, "cancellation connection"); return }

    await control.setDelays(["sessions.list": 2500])
    let outcome = Scripted<String>("pending")
    let started = Date()
    let request = Task { @MainActor in
        do {
            _ = try await connection.request("sessions.list", [:], timeout: 20)
            outcome.value = "answered"
        } catch is CancellationError {
            outcome.value = "cancelled"
        } catch {
            outcome.value = "failed: \(error)"
        }
    }
    try? await Task.sleep(for: .milliseconds(200))
    request.cancel()
    let resolved = await waitFor("cancelled request", timeout: 1.5, every: 20) { outcome.value != "pending" }
    check(resolved && outcome.value == "cancelled", "cancelled request throws CancellationError promptly (\(outcome.value), \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
    // Let the delayed response for the abandoned id arrive; it must be ignored.
    try? await Task.sleep(for: .milliseconds(2600))
    await control.setDelays([:])
    let after = try? await connection.request("sessions.list", [:], timeout: 10)
    check(after?["sessions"]?.array?.isEmpty == false, "connection still works after the late response for a cancelled request")
}
