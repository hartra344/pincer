import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class Clips: ReadAloudClipPlaying {
    func play(_ clip: TTSClip) async -> Bool { true }
    func stop() {}
}

@MainActor
private final class Device: ReadAloudLocalSpeaking {
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool { true }
    func stop() {}
}

/// The Gateway call never times out on the wall clock; the tests wait on state instead (as in #569).
private let neverTimesOut: @Sendable (Duration) async -> Void = { _ in
    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
}

@MainActor
private func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(120) // only a safety net; every wait is on state
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
private func run(scopes: [String] = ["operator.write"], speak: @escaping @MainActor () throws -> String, source: String? = nil,
                 configured: Bool = true, provider: String = "elevenlabs") async -> ReadAloudController
{
    let scratch = ScratchDefaults()
    if let source { scratch.defaults.set(source, forKey: "pincer.readAloud.source") }
    let controller = ReadAloudController(clipPlayer: Clips(), localSpeaker: Device(), defaults: scratch.defaults)
    controller.gatewayTimer = neverTimesOut
    let gateway = GatewayVoiceModel(methods: { nil }, scopes: { scopes }, request: { method, _ in
        switch method {
        case "tts.status":
            return Fixtures.json("{\"enabled\":false,\"provider\":\"\(provider)\",\"providerStates\":[{\"id\":\"\(provider)\",\"label\":\"ElevenLabs\",\"configured\":\(configured)},{\"id\":\"openai\",\"label\":\"OpenAI\",\"configured\":true}]}")
        case "tts.speak": return Fixtures.json(try speak())
        default: return [:]
        }
    })
    await gateway.refresh()
    controller.toggle(messageId: "m", text: "Hello.", gateway: gateway)
    await until { controller.phase == .idle && controller.lastSource != nil }
    return controller
}

private func reply(_ provider: String) -> String {
    "{\"audioBase64\":\"AAEC\",\"provider\":\"\(provider)\",\"mimeType\":\"audio/wav\",\"fileExtension\":\"wav\"}"
}

@Suite("Read Aloud last fallback")
@MainActor
struct ReadAloudFallbackTests {
    @Test func selectedProviderSpeakingLeavesNoFallback() async {
        let c = await run(speak: { reply("elevenlabs") })
        #expect(c.lastSource == .gateway("elevenlabs") && c.lastFallback == nil)
    }

    @Test func anotherProviderSpeakingRecordsAFallback() async {
        let c = await run(speak: { reply("openai") })
        #expect(c.lastSource == .gateway("openai") && c.lastFallback != nil)
    }

    @Test func gatewayErrorRecordsTheProviderMessage() async {
        let c = await run(speak: { throw GatewayError.rpc(code: "UNAVAILABLE", message: "ElevenLabs API error (401)", details: nil) })
        #expect(c.lastSource == .device && c.lastFallback == .other("ElevenLabs API error (401)"))
    }

    @Test func deviceSettingIsRecorded() async {
        let c = await run(speak: { reply("elevenlabs") }, source: "device")
        #expect(c.lastSource == .device && c.lastFallback == .deviceOnlySetting)
    }

    @Test func noWriteScopeIsRecorded() async {
        let c = await run(scopes: ["operator.read"], speak: { reply("elevenlabs") })
        #expect(c.lastSource == .device && c.lastFallback == .noWritePermission)
    }

    @Test func unconfiguredProviderIsRecorded() async {
        let c = await run(speak: { reply("openai") }, configured: false)
        #expect(c.lastSource == .device || c.lastFallback != nil)
    }

    @Test func aLaterSuccessClearsTheFallback() async {
        let scratch = ScratchDefaults()
        let controller = ReadAloudController(clipPlayer: Clips(), localSpeaker: Device(), defaults: scratch.defaults)
        controller.gatewayTimer = neverTimesOut
        var failing = true
        let gateway = GatewayVoiceModel(methods: { nil }, scopes: { ["operator.write"] }, request: { method, _ in
            guard method == "tts.speak" else { return [:] }
            if failing { throw GatewayError.rpc(code: "UNAVAILABLE", message: "down", details: nil) }
            return Fixtures.json(reply("openai"))
        })
        controller.toggle(messageId: "a", text: "One.", gateway: gateway)
        await until { controller.lastSource != nil && controller.phase == .idle }
        #expect(controller.lastFallback == .other("down"))
        failing = false
        controller.toggle(messageId: "b", text: "Two.", gateway: gateway)
        await until { controller.lastSource != .device && controller.phase == .idle }
        #expect(controller.lastSource == .gateway("openai") && controller.lastFallback == nil)
    }
}
