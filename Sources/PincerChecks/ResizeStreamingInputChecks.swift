import Foundation
import PincerKit

/// The native resize probe owns geometry. This complementary demo check verifies that the
/// real store supplies a stable live-row identity while its text grows, then settles the final text.
@MainActor
func runDemoResizeStreamingInputs() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let ready = await waitFor("demo resize streaming inputs") {
        gateway.state.isConnected && !gateway.sessions.isEmpty
    }
    check(ready, "resize inputs demo: connected")
    guard ready else { return }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let before = chat.entries.count
    var ids: Set<String> = []
    var lengths: Set<Int> = []
    var latestBody = ""
    await chat.send("long")
    let finished = await waitFor("resize streaming input reply", timeout: 30, every: 10) {
        if case let .assistant(turn)? = chat.entries.last, turn.isStreaming, !turn.body.isEmpty {
            ids.insert(turn.id)
            lengths.insert(turn.body.utf8.count)
            latestBody = turn.body
        }
        return !chat.isRunning && chat.entries.count > before
    }
    check(finished, "resize inputs demo: the streamed reply finishes")
    check(ids.count == 1 && lengths.count > 1,
          "resize inputs demo: the same live-row identity receives growing text")
    if case let .assistant(turn)? = chat.entries.last {
        check(!turn.isStreaming && turn.body.count > 3000 && turn.body.hasPrefix(latestBody),
              "resize inputs demo: final committed text includes the observed streaming prefix")
    } else {
        check(false, "resize inputs demo: a committed assistant row remains")
    }
}
