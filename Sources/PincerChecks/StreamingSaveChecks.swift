import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

/// #298 exercises the foreground store's automatic save path with an injected clock.
@MainActor
func runStreamingSaveChecks() {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: GatewayProfile(name: "Streaming saves", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults)
    let chat = gateway.chat(for: "agent:main:dashboard:save-check")
    defer { chat.stopCaching() }
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    chat.saveNow = { now }
    chat.waitForSaveDeadline = { _ in throw CancellationError() }
    chat.hasLoaded = true
    chat.live = LiveRun(runId: "save-check")
    chat.items = [ChatItem(id: "first", role: .user, blocks: [.text("First committed message")])]
    let firstDeadline = now.addingTimeInterval(5)
    check(chat.saveDeadline == firstDeadline, "stream saves: first dirty state gets a five-second deadline")
    now = now.addingTimeInterval(4)
    chat.items.append(ChatItem(id: "second", role: .user, blocks: [.text("Next committed message")]))
    check(chat.saveDeadline == firstDeadline, "stream saves: later changes cannot postpone the first deadline")
    chat.flushScheduledSave()
    check(chat.saveDeadline == now, "stream saves: a terminal flush schedules the dirty snapshot immediately")
    chat.stopCaching()
    check(chat.saveDeadline == nil, "stream saves: cancellation retires the deadline")

    let idle = gateway.chat(for: "agent:main:dashboard:idle-save-check")
    defer { idle.stopCaching() }
    idle.saveNow = { now }
    idle.waitForSaveDeadline = { _ in throw CancellationError() }
    idle.hasLoaded = true
    idle.items = [ChatItem(id: "idle", role: .user, blocks: [.text("Ordinary transcript change")])]
    check(idle.saveDeadline == now.addingTimeInterval(1), "stream saves: idle changes keep the ordinary one-second debounce")
    let earlier = idle.saveDeadline
    idle.live = LiveRun(runId: "search-check")
    idle.items.append(ChatItem(id: "reply", role: .assistant, blocks: [.text("Reply step")]))
    check(idle.saveDeadline == earlier, "stream saves: starting a run preserves an earlier pending save")
    idle.handleSessionMessage(["message": ["role": "user", "content": "Searchable user message", "__openclaw": ["id": "search-check-user"]]])
    check(idle.saveDeadline == now, "stream saves: a committed user message flushes promptly for search")
    idle.items.append(ChatItem(id: "reply-next", role: .assistant, blocks: [.text("Next reply step")]))
    check(idle.saveDeadline == now, "stream saves: reply output cannot postpone the user-message flush")
    #endif
}

/// The demo's real streamed tool reply runs through the same scheduler and terminal hook.
@MainActor
func runDemoStreamingSaveChecks() async {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let ready = await waitFor("demo streaming save") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "stream saves demo: connected")
    guard ready else { return }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    var delays: [TimeInterval] = []
    let realWaiter = chat.waitForSaveDeadline
    let now = chat.saveNow
    chat.waitForSaveDeadline = { deadline in
        delays.append(deadline.timeIntervalSince(now()))
        try await realWaiter(deadline)
    }
    let before = chat.entries.count
    await chat.send("show me a tool and an image")
    let done = await waitFor("demo streamed reply completes", timeout: 20) {
        !chat.isRunning && chat.entries.count > before + 1
    }
    check(done, "stream saves demo: streamed reply completes")
    check(delays.contains { $0 > 1 && $0 <= 5 }, "stream saves demo: committed streaming changes use the bounded window")
    check(delays.contains { $0 <= 0 }, "stream saves demo: the real terminal event flushes without the ordinary delay")
    #endif
}
