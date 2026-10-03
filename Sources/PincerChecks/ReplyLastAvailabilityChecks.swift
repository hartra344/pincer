import Foundation
@testable import PincerKit

@MainActor
func runDemoReplyLastAvailabilityChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("Reply Last Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.sessions["agent:main:dashboard:trip"] != nil
    }
    check(connected, "Reply Last connects to actual seeded Demo")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:dashboard:trip")
    await chat.load()
    await chat.replyLastPreparation.waitUntilIdle()
    let expected = chat.items.last { $0.isReplyable && ($0.role == .user || !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }?.transcriptId
    check(expected != nil && chat.latestReplyableId == expected, "actual seeded transcript preserves Reply Last eligibility")
    #if DEBUG
    let original = chat.items
    defer { chat.items = original }
    let id = UUID().uuidString
    let blocks = await Task.detached { [ContentBlock.text(""),
        .text(String(repeating: " ", count: 1_048_576)), .text(String(repeating: "x", count: 1_048_576))] }.value
    var large = ChatItem(id: id, role: .assistant, blocks: blocks)
    large.transcriptId = id
    chat.items.append(large)
    ReplyLastAvailabilityDebugProbe.reset(tracking: id)
    defer { ReplyLastAvailabilityDebugProbe.unregister(tracking: id) }
    check(chat.latestReplyableId == nil, "cold unknown connected target cannot select an older message")
    await chat.replyLastPreparation.waitUntilIdle()
    check(chat.latestReplyableId == id, "connected actual availability keeps content beyond a giant whitespace prefix")
    check(ReplyLastAvailabilityDebugProbe.stats(for: id).mainNormalizations == 0,
          "connected actual Reply Last validation does not normalize 2 MiB on Main")
    check(ReplyLastAvailabilityDebugProbe.stats(for: id).offMainNormalizations > 0, "actual connected availability predicate runs off-main")
    #endif
}
