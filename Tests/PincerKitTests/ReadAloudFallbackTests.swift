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

@MainActor
private func run(scopes: [String] = ["operator.write"], speak: @escaping @MainActor () throws -> String, source: String? = nil,
                 configured: Bool = true, provider: String = "elevenlabs") async -> ReadAloudController
{
    let scratch = ScratchDefaults()
    if let source { scratch.defaults.set(source, forKey: "pincer.readAloud.source") }
    let controller = ReadAloudController(clipPlayer: Clips(), localSpeaker: Device(), defaults: scratch.defaults, gatewayTimeout: .seconds(30))
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
    let deadline = ContinuousClock.now + .seconds(20)
    while controller.phase != .idle || controller.lastSource == nil {
        if ContinuousClock.now > deadline { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
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
        let controller = ReadAloudController(clipPlayer: Clips(), localSpeaker: Device(), defaults: scratch.defaults, gatewayTimeout: .seconds(30))
        var failing = true
        let gateway = GatewayVoiceModel(methods: { nil }, scopes: { ["operator.write"] }, request: { method, _ in
            guard method == "tts.speak" else { return [:] }
            if failing { throw GatewayError.rpc(code: "UNAVAILABLE", message: "down", details: nil) }
            return Fixtures.json(reply("openai"))
        })
        controller.toggle(messageId: "a", text: "One.", gateway: gateway)
        while controller.lastSource == nil || controller.phase != .idle { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.lastFallback == .other("down"))
        failing = false
        controller.toggle(messageId: "b", text: "Two.", gateway: gateway)
        while controller.lastSource == .device || controller.phase != .idle { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.lastSource == .gateway("openai") && controller.lastFallback == nil)
    }
}
