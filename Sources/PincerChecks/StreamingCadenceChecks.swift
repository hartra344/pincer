import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runStreamingCadenceChecks() {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: GatewayProfile(name: "Cadence check", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults)
    let key = "agent:main:cadence-check"
    let chat = gateway.chat(for: key)
    defer { chat.pendingFlush?.cancel(); chat.stopCaching() }
    func delta(_ chunk: String, full: String) {
        chat.handleChat(["runId": "cadence-check", "sessionKey": .string(key), "state": "delta",
                         "deltaText": .string(chunk), "message": ["role": "assistant", "content":
                            [["type": "text", "text": .string(full)]]]])
    }
    func body() -> String? {
        chat.entries.reversed().compactMap { entry -> String? in
            if case let .assistant(turn) = entry, turn.isStreaming { return turn.body }
            return nil
        }.first
    }
    delta("A", full: "A")
    check(body() == "A", "cadence: the first delta publishes immediately")
    // Control elapsed input time directly; do not rely on wall-clock sleeps or scheduling.
    chat.lastPublishAt = Date().addingTimeInterval(-0.020)
    delta("B", full: "AB")
    check(body() == "AB" && chat.pendingFlush == nil,
          "cadence: the next input after one 60 Hz frame publishes without a trailing wait")
    chat.lastPublishAt = .now
    delta("C", full: "ABC")
    check(body() == "AB" && chat.pendingFlush != nil,
          "cadence: same-frame bursts remain coalesced")
    chat.flushLive()
    check(body() == "ABC" && chat.pendingFlush == nil,
          "cadence: explicit flush preserves the complete pending text and retires its timer")
    #endif
}
