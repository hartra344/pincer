import Foundation
@testable import PincerKit

@MainActor func runAutoReadCallbackOrderingChecks() async {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    let chat = gateway.chat(for: "agent:probe:callback-ordering")
    var delivered: [ChatItem] = []
    chat.onFinalAssistantReply = { delivered.append($0) }
    defer { chat.onFinalAssistantReply = nil }
    let id = "callback-ordering-\(UUID().uuidString)"
    SpeechText.resetSpeakabilityDebugStats(tracking: id)
    defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: id) }
    chat.handleChat(["runId": "ordering-run", "sessionKey": .string(chat.sessionKey), "state": "final"])
    chat.handleSessionMessage(["message": ["role": "assistant", "content": [["type": "text", "text": "Actual accepted reply."]], "__openclaw": ["id": .string(id)]]])
    check(delivered.count == 1, "neutral: obsolete synchronous accepted-callback premise")
    let finished = await waitFor("actual accepted callback completion", timeout: 5) {
        delivered.count == 1 && chat.liveReplyPreparationQueue.isIdle
    }
    check(finished && delivered.first == chat.message(withId: id), "actual async callback preserves full committed reply")
    let stats = SpeechText.speakabilityDebugStats(for: id)
    check(stats.mainThreadNormalizations == 0 && stats.offMainNormalizations >= 1,
          "actual accepted callback normalizes off-main")
    #endif
}
