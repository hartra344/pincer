import Foundation
import PincerKit

// Failed-send retry and the offline outbox (issue #46): the demo's seeded failed message and its
// Retry, and against the mock Gateway: queued while disconnected → sent once on reconnect, in
// order; rejected sends stay failed; drops mid-send resend with the same key without duplicating;
// and the outbox surviving a relaunch.

@MainActor
private func unsent(_ chat: ChatStore) -> [ChatItem] {
    chat.items.filter { $0.outboxState != nil }
}

@MainActor
private func outboxItem(_ chat: ChatStore, _ id: String) -> ChatItem? {
    chat.items.first { $0.idempotencyKey == id && $0.outboxState != nil }
}

/// Committed (not pending) user messages in `chat` whose text is exactly `text`.
@MainActor
private func committedCopies(_ chat: ChatStore, _ text: String) -> Int {
    chat.items.filter { $0.role == .user && !$0.isPending && $0.plainText == text }.count
}

private func isFailed(_ state: OutboxState?, retryable: Bool) -> Bool {
    if case let .failed(failure)? = state { return failure.retryable == retryable }
    return false
}

@MainActor
private func connectForOutbox(_ profile: GatewayProfile, _ label: String) async -> GatewayStore? {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor(label, timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "\(label) connected")
    if !connected { gateway.stop() }
    return connected ? gateway : nil
}

// MARK: Pure

@MainActor
func checkOutboxLogic() {
    print("Outbox")
    let now = Date()
    func entry(_ id: String, _ key: String = "a") -> OutboxEntry { OutboxEntry(id: id, sessionKey: key, text: id, createdAt: now) }
    var box = Outbox()
    for item in [entry("1"), entry("2"), entry("x", "b")] { box.enqueue(item) }
    box.markSending(id: "1")
    box.markFailed(id: "1", kind: .rejected("bad"))
    check(box.nextToSend(sessionKey: "a") == nil && box.nextToSend()?.id == "x", "a failed head blocks only its own chat")
    box.connectionLost()
    check(box.nextToSend(sessionKey: "a") == nil, "reconnecting doesn't resend a rejection")
    box.retry(id: "1")
    var order: [String] = []
    while let next = box.nextToSend() {
        box.markSending(id: next.id)
        order.append(next.id)
        box.markSent(id: next.id)
    }
    check(order == ["1", "2", "x"] && box.isEmpty, "Retry resends with the same key, then the rest in order (\(order))")
    box.enqueue(entry("3"))
    box.markSending(id: "3")
    box.connectionLost()
    box.reconcile(committedKeys: ["3"])
    check(box.isEmpty, "a send that landed before the drop is reconciled, not resent")
    check(SendFailure.classify(GatewayError.rpc(code: "INVALID_REQUEST", message: "bad", details: nil)) == .rejected("bad")
          && SendFailure.classify(GatewayError.rpc(code: "UNAVAILABLE", message: "busy", details: ["retryable": true])) == .transient
          && SendFailure.classify(GatewayError.rpc(code: "NOT_PAIRED", message: "no", details: nil)) == .authRevoked
          && SendFailure.classify(GatewayError.closed("mock drop")) == .transient,
          "send failures classify as rejected / transient / auth revoked")
}

// MARK: Demo

@MainActor
func runDemoOutbox() async {
    guard let gateway = await connectForOutbox(.demo(), "demo for the outbox") else { return }
    defer { gateway.stop() }
    let chat = gateway.chat(for: DemoOutbox.sessionKey)
    await chat.load()
    _ = await waitFor("demo dinner history") { chat.hasLoaded }
    let id = DemoOutbox.failedId
    let seeded = await waitFor("seeded failed message") { outboxItem(chat, id) != nil }
    check(seeded, "demo: the Dinner party chat shows a failed message")
    guard seeded, let item = outboxItem(chat, id) else { return }
    // A drop would keep it Queued; the seed is a timeout while connected, which really reads Failed.
    let reason: String? = if case let .failed(failure)? = item.outboxState { failure.message } else { nil }
    check(reason == "The gateway timed out.", "demo: it failed on a timeout, not a drop (\(reason ?? "nil"))")
    check(isFailed(item.outboxState, retryable: true) && item.isPending && item.role == .user,
          "demo: it reads Failed with Retry (\(String(describing: item.outboxState)))")
    check(chat.items.last?.idempotencyKey == id, "demo: the failed message is the chat's latest")
    let text = item.plainText
    check(gateway.unsentCount == 1, "demo: one unsent message (\(gateway.unsentCount))")

    // Nothing resends it on its own; Retry sends it once with the same key.
    try? await Task.sleep(for: .milliseconds(500))
    check(isFailed(outboxItem(chat, id)?.outboxState, retryable: true) && committedCopies(chat, text) == 0,
          "demo: a failed message waits for Retry")
    chat.retry(outboxId: id)
    let delivered = await waitFor("demo retry delivered", timeout: 15) {
        gateway.unsentCount == 0 && outboxItem(chat, id) == nil && committedCopies(chat, text) == 1
    }
    check(delivered, "demo: Retry delivers it (\(committedCopies(chat, text)) cop(ies), \(gateway.unsentCount) unsent)")
    _ = await waitFor("demo reply", timeout: 15) { !chat.isRunning }
    await chat.load(force: true)
    check(committedCopies(chat, text) == 1 && !chat.items.contains { $0.idempotencyKey == id && $0.isPending },
          "demo: exactly one copy after reload (\(committedCopies(chat, text)))")
}

// MARK: Live

/// A fresh store (its own profile, so its own cache) that reads the chat straight from `chat.history`.
@MainActor
private func historyCopies(url: String, token: String, key: String, texts: [String]) async -> [Int]? {
    let profile = GatewayProfile(name: "Mock outbox verifier", url: url, authMode: .token)
    profile.secret = token
    guard let verifier = await connectForOutbox(profile, "outbox verifier") else { return nil }
    defer { verifier.stop() }
    let chat = verifier.chat(for: key)
    await chat.load(force: true)
    _ = await waitFor("verifier history") { chat.hasLoaded }
    return texts.map { committedCopies(chat, $0) }
}

@MainActor
private func historyOrder(url: String, token: String, key: String, texts: [String]) async -> [String] {
    let profile = GatewayProfile(name: "Mock outbox order", url: url, authMode: .token)
    profile.secret = token
    guard let verifier = await connectForOutbox(profile, "outbox order verifier") else { return [] }
    defer { verifier.stop() }
    let chat = verifier.chat(for: key)
    await chat.load(force: true)
    _ = await waitFor("verifier history") { chat.hasLoaded }
    return chat.items.filter { $0.role == .user && !$0.isPending && texts.contains($0.plainText) }.map(\.plainText)
}

@MainActor
func runLiveOutbox(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock outbox", url: url, authMode: .token)
    profile.secret = token
    guard let gateway = await connectForOutbox(profile, "mock for the outbox") else { return }
    guard let key = await gateway.createSession(agentId: "main", label: "Outbox checks", select: false) else {
        gateway.stop()
        return check(false, "created a chat for the outbox checks")
    }
    let chat = gateway.chat(for: key)
    await chat.load()
    _ = await waitFor("outbox chat loaded") { chat.hasLoaded }
    let nonce = UUID().uuidString.prefix(6)

    // 1. Offline: the socket drops mid-send (before the Gateway accepts); what's composed while
    //    it's down queues, and everything goes out once, in order, on reconnect.
    let first = "outbox first \(nonce) [mock:drop-once]"
    let second = "outbox second \(nonce)"
    let third = "outbox third \(nonce)"
    let firstOutcome = Task { await chat.sendMessage(first) }
    let dropped = await waitFor("socket dropped", timeout: 10, every: 10) { !gateway.state.isConnected }
    check(dropped, "drop-once closes the connection")
    let secondOutcome = await chat.sendMessage(second)
    let thirdOutcome = await chat.sendMessage(third)
    check(secondOutcome == .queued && thirdOutcome == .queued,
          "composing while disconnected queues (\(secondOutcome), \(thirdOutcome))")
    check(unsent(chat).filter { $0.outboxState == .queued }.count >= 2 && !gateway.state.isConnected,
          "queued messages show inline while offline (\(unsent(chat).map { String(describing: $0.outboxState) }))")
    let firstId = gateway.outbox.entries.first { $0.text == first }?.id
    _ = await firstOutcome.value
    let flushed = await waitFor("outbox flushed after reconnect", timeout: 30) {
        gateway.state.isConnected && gateway.unsentCount == 0
    }
    check(flushed, "reconnecting sends the queue (\(gateway.unsentCount) left)")
    _ = await waitFor("runs settle", timeout: 30) { !chat.isRunning }
    try? await Task.sleep(for: .milliseconds(300))
    let copies = await historyCopies(url: url, token: token, key: key, texts: [first, second, third])
    check(copies == [1, 1, 1], "chat.history has each message exactly once (\(copies ?? []))")
    let order = await historyOrder(url: url, token: token, key: key, texts: [first, second, third])
    check(order == [first, second, third], "…in the order they were written (\(order))")
    check(firstId != nil, "the dropped send stayed in the outbox with its key")

    // 2. Rejected: a non-retryable INVALID_REQUEST fails inline and is never resent on its own.
    let rejected = "outbox rejected \(nonce) [mock:reject-send]"
    let rejectedOutcome = await chat.sendMessage(rejected)
    if case .failedInline = rejectedOutcome {} else { check(false, "a rejected send fails inline (\(rejectedOutcome))") }
    let rejectedEntry = gateway.outbox.entries.first { $0.text == rejected }
    check(isFailed(rejectedEntry?.state, retryable: false) && rejectedEntry?.attempts == 1,
          "rejected → Failed, not retryable (\(String(describing: rejectedEntry?.state)), \(rejectedEntry?.attempts ?? -1) attempt(s))")
    check(rejectedEntry.flatMap { outboxItem(chat, $0.id) }.map { isFailed($0.outboxState, retryable: false) } == true,
          "the rejected message shows inline as Failed")
    // A reconnect doesn't resend it either.
    gateway.reconnectIfNeeded()
    try? await Task.sleep(for: .seconds(2))
    _ = await waitFor("reconnected", timeout: 20) { gateway.state.isConnected }
    await gateway.flushOutbox()
    let stillRejected = gateway.outbox.entries.first { $0.text == rejected }
    check(stillRejected?.attempts == 1 && isFailed(stillRejected?.state, retryable: false),
          "rejected message isn't retried automatically (\(stillRejected?.attempts ?? -1) attempt(s))")
    // Delete removes it for good.
    if let id = rejectedEntry?.id {
        chat.deleteQueued(outboxId: id)
        check(gateway.outbox.entry(id: id) == nil && outboxItem(chat, id) == nil
              && !chat.items.contains { $0.idempotencyKey == id }, "Delete discards the failed message")
    }

    // 3. Retryable UNAVAILABLE while connected: Failed with Retry; Retry resends once with the same key.
    let busy = "outbox busy \(nonce) [mock:unavailable-once]"
    _ = await chat.sendMessage(busy)
    let busyEntry = gateway.outbox.entries.first { $0.text == busy }
    check(isFailed(busyEntry?.state, retryable: true), "retryable UNAVAILABLE → Failed with Retry (\(String(describing: busyEntry?.state)))")
    if let id = busyEntry?.id {
        chat.retry(outboxId: id)
        let landed = await waitFor("busy retry delivered", timeout: 20) { gateway.outbox.entry(id: id) == nil }
        check(landed, "Retry delivers it")
        _ = await waitFor("runs settle", timeout: 30) { !chat.isRunning }
    }

    // 4. Ambiguous: the Gateway accepts, then the socket drops before the ack. The resend on
    //    reconnect reuses the key (or reconciles against history), so there's one copy.
    let ambiguous = "outbox ambiguous \(nonce) [mock:drop-after-accept]"
    let ambiguousSend = Task { await chat.sendMessage(ambiguous) }
    let ambiguousDropped = await waitFor("ambiguous drop", timeout: 10, every: 10) { !gateway.state.isConnected }
    check(ambiguousDropped, "drop-after-accept closes the connection")
    var ambiguousId: String?
    _ = await waitFor("ambiguous key known", timeout: 2, every: 10) {
        ambiguousId = gateway.outbox.entries.first { $0.text == ambiguous }?.id
        return ambiguousId != nil
    }
    _ = await ambiguousSend.value
    let settled = await waitFor("ambiguous send settled", timeout: 30) {
        gateway.state.isConnected && gateway.unsentCount == 0
    }
    check(settled, "the ambiguous send settles after reconnect (\(gateway.unsentCount) unsent, key \(ambiguousId ?? "gone"))")
    _ = await waitFor("runs settle", timeout: 30) { !chat.isRunning }
    try? await Task.sleep(for: .milliseconds(300))
    let afterDrops = await historyCopies(url: url, token: token, key: key, texts: [busy, ambiguous, rejected])
    check(afterDrops == [1, 1, 0], "busy and ambiguous land once, rejected never (\(afterDrops ?? []))")
    await chat.load(force: true)
    check(committedCopies(chat, ambiguous) == 1 && !chat.items.contains { $0.plainText == ambiguous && $0.isPending },
          "Pincer's own view shows one copy, nothing pending (\(committedCopies(chat, ambiguous)))")
    gateway.stop()
    try? await Task.sleep(for: .milliseconds(300))

    await runLiveOutboxRelaunch(url: url, token: token, key: key)
}

/// Queued while the Gateway is unreachable, the app quits; the next launch sends it once.
@MainActor
private func runLiveOutboxRelaunch(url: String, token: String, key: String) async {
    let profile = GatewayProfile(name: "Mock outbox relaunch", url: url, authMode: .token)
    profile.secret = token
    guard let first = await connectForOutbox(profile, "outbox relaunch (first launch)") else { return }
    let chat = first.chat(for: key)
    await chat.load()
    _ = await waitFor("relaunch chat loaded") { chat.hasLoaded }
    let text = "outbox after relaunch \(UUID().uuidString.prefix(6))"
    // Drop the socket by hand: a send that closes it, then queue while it's down.
    let trigger = "outbox relaunch trigger \(UUID().uuidString.prefix(6)) [mock:drop-once]"
    let triggerSend = Task { await chat.sendMessage(trigger) }
    _ = await waitFor("relaunch drop", timeout: 10, every: 10) { !first.state.isConnected }
    let queued = await chat.sendMessage(text)
    check(queued == .queued, "queued while down (\(queued))")
    first.stop()
    _ = await triggerSend.value
    let saved = await waitFor("outbox saved", timeout: 5) {
        OutboxStore.file(gatewayId: profile.id).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    }
    check(saved, "the outbox is saved to disk")
    try? await Task.sleep(for: .milliseconds(300))

    let second = GatewayStore(profile: profile)
    second.start()
    defer { second.stop() }
    let sent = await waitFor("relaunch flush", timeout: 30) {
        second.state.isConnected && !second.sessions.isEmpty && second.unsentCount == 0
    }
    check(sent, "the next launch sends what was queued (\(second.unsentCount) left)")
    let secondChat = second.chat(for: key)
    _ = await waitFor("relaunch runs settle", timeout: 30) { !secondChat.isRunning }
    try? await Task.sleep(for: .milliseconds(300))
    let copies = await historyCopies(url: url, token: token, key: key, texts: [trigger, text])
    check(copies == [1, 1], "…exactly once each, across the relaunch (\(copies ?? []))")
    let cleared = await waitFor("outbox file cleared", timeout: 5) {
        OutboxStore.file(gatewayId: profile.id).map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? true
    }
    check(cleared, "an empty outbox leaves no file")
}
