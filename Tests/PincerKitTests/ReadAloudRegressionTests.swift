import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class LateSpeaker: ReadAloudLocalSpeaking {
    var spoken: [String] = []
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        spoken.append(text)
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Doesn't finish the old utterance: its completion arrives late, like a stale delegate callback.
    func stop() {}

    func finishOldest() { if !waiting.isEmpty { waiting.removeFirst().resume(returning: true) } }
    func finishAll() { while !waiting.isEmpty { waiting.removeFirst().resume(returning: true) } }
}

@MainActor
private final class NoClips: ReadAloudClipPlaying {
    func play(_ clip: TTSClip) async -> Bool { false }
    func stop() {}
}

@MainActor
@Suite("Read Aloud regressions")
struct ReadAloudRegressionTests {
    @Test func lateCompletionOfReplacedSpeechKeepsNewPhase() async {
        let scratch = ScratchDefaults()
        scratch.defaults.set("device", forKey: "pincer.readAloud.source")
        let speaker = LateSpeaker()
        let controller = ReadAloudController(clipPlayer: NoClips(), localSpeaker: speaker, defaults: scratch.defaults)
        controller.toggle(messageId: "m1", text: "First.", gateway: nil)
        for _ in 0 ..< 100 where controller.phase != .speaking("m1") { try? await Task.sleep(for: .milliseconds(10)) }
        controller.toggle(messageId: "m2", text: "Second.", gateway: nil)
        for _ in 0 ..< 100 where speaker.spoken.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        speaker.finishOldest()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.phase == .speaking("m2"))
        speaker.finishAll()
        for _ in 0 ..< 100 where controller.phase != .idle { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.phase == .idle)
    }

    @Test func pricesAreNotMath() {
        #expect(SpeechText.plain(fromMarkdown: "It costs $5 and $10 today.") == "It costs $5 and $10 today.")
        #expect(SpeechText.plain(fromMarkdown: "Solve $x^2$ now.") == "Solve x^2 now.")
    }

    @Test func comparisonsSurviveButTagsGo() {
        #expect(SpeechText.plain(fromMarkdown: "a < b and c > d") == "a < b and c > d")
        #expect(SpeechText.plain(fromMarkdown: "Hi <b>there</b><br/>friend") == "Hi therefriend")
    }

    @Test func tableRowsEndWithPause() {
        let text = SpeechText.plain(fromMarkdown: "| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(text == "A, B. 1, 2.")
    }

    @Test func unconfiguredProviderIsNeverSet() async {
        var calls: [String] = []
        let model = GatewayVoiceModel(request: { method, _ in
            calls.append(method)
            switch method {
            case "tts.status": return Fixtures.json(#"{"enabled":false,"auto":"off","provider":"openai","providerStates":[{"id":"openai","label":"OpenAI","configured":true},{"id":"eleven","label":"Eleven","configured":false}]}"#)
            default: return [:]
            }
        })
        await model.refresh()
        calls.removeAll()
        await #expect(throws: (any Error).self) { try await model.setProvider("eleven") }
        #expect(!calls.contains("tts.setProvider"))
    }

    @Test func statusLoadsOnceLazily() async {
        var statusCalls = 0
        let model = GatewayVoiceModel(request: { method, _ in
            if method == "tts.status" { statusCalls += 1 }
            return Fixtures.json(#"{"enabled":false,"auto":"off","provider":"openai","providerStates":[{"id":"openai","label":"OpenAI","configured":false}]}"#)
        })
        #expect(model.canSpeak)
        await model.loadStatusIfNeeded()
        await model.loadStatusIfNeeded()
        #expect(statusCalls == 1)
        #expect(!model.canSpeak)
        model.handleReconnect()
        await model.loadStatusIfNeeded()
        #expect(statusCalls == 2)
    }

    @Test func timeoutIsFifteenSeconds() {
        #expect(ReadAloudSettings.gatewayTimeout == .seconds(15))
    }
}
