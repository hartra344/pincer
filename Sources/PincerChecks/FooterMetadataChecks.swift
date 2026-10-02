import Foundation
import PincerKit

/// Native compact/wide geometry is covered in CompactFooterTests. Keep the visible demo's
/// per-message model, timestamp, and action targets available to that same footer pipeline.
@MainActor
func runDemoFooterMetadataChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    defer { gateway.stop() }
    let key = "agent:main:dashboard:rate-limiter"
    let ready = await waitFor("demo footer metadata") {
        gateway.state.isConnected && gateway.sessions[key] != nil
    }
    check(ready, "footer demo: seeded chat is available")
    guard ready else { return }
    let chat = gateway.chat(for: key)
    await chat.load()
    let turns = chat.entries.compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry, !turn.text.isEmpty { return turn }
        return nil
    }
    let userItems = chat.entries.compactMap { entry -> ChatItem? in
        if case let .user(item) = entry { return item }
        return nil
    }
    check(!turns.isEmpty, "footer demo: committed assistant replies are present")
    check(turns.allSatisfy { turn in
        turn.textTimestamps.count == turn.text.count
            && turn.textTimestamps.allSatisfy { $0 != nil }
            && turn.textModelNames.count == turn.text.count
            && turn.textModelNames.allSatisfy { $0?.isEmpty == false }
            && turn.textIds.count == turn.text.count
            && turn.textIds.allSatisfy { $0?.isEmpty == false }
            && !turn.isStreaming
    }, "footer demo: every reply retains full metadata and targets for Copy, Reply, Listen, and React")
    check(userItems.contains { $0.plainText.contains("Sketch how the API rate limiter should work")
        && $0.timestamp != nil && $0.model == nil },
          "footer demo: the seeded user message supplies a timestamp without an assistant model")
}
