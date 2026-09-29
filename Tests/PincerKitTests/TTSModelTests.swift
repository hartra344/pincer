import Foundation
import Testing
@testable import PincerKit

@Suite("TTS models")
struct TTSModelTests {
    @Test func statusFromUpstreamShape() {
        let status = TTSStatus(Fixtures.json(#"""
        {"enabled":true,"auto":"always","provider":"openai","persona":"narrator",
         "personas":[{"id":"narrator","label":"Narrator","description":"Warm","provider":"openai"},{"id":"concise"}],
         "fallbackProvider":"elevenlabs","fallbackProviders":["elevenlabs"],"prefsPath":"/x/tts.json",
         "providerStates":[{"id":"openai","label":"OpenAI","configured":true},{"id":"elevenlabs","label":"ElevenLabs","configured":false}],
         "futureField":{"a":1}}
        """#))
        #expect(status?.enabled == true && status?.auto == "always" && status?.provider == "openai")
        #expect(status?.persona == "narrator")
        #expect(status?.personas.map(\.id) == ["narrator", "concise"])
        #expect(status?.personas[0].displayName == "Narrator" && status?.personas[1].displayName == "concise")
        #expect(status?.personas[1].label == nil && status?.personas[1].provider == nil)
        #expect(status?.fallbackProviders == ["elevenlabs"])
        #expect(status?.providerStates.map(\.configured) == [true, false])
        #expect(status?.hasConfiguredProvider == true)
    }

    @Test func statusToleratesMissingFieldsAndNullPersona() {
        let status = TTSStatus(Fixtures.json(#"{"enabled":false,"provider":"openai","persona":null}"#))
        #expect(status?.persona == nil && status?.auto == "off")
        #expect(status?.personas.isEmpty == true && status?.providerStates.isEmpty == true && status?.fallbackProviders.isEmpty == true)
        #expect(status?.hasConfiguredProvider == true, "unknown provider states count as usable")
        #expect(TTSStatus(Fixtures.json("[]")) == nil)
    }

    @Test func noConfiguredProvider() {
        let status = TTSStatus(Fixtures.json(#"{"enabled":false,"provider":"x","providerStates":[{"id":"x","label":"X","configured":false}]}"#))
        #expect(status?.hasConfiguredProvider == false)
    }

    @Test func statusDecodesWithJSONDecoder() throws {
        let data = Data(#"{"enabled":true,"auto":"off","provider":"openai","providerStates":[{"id":"openai","label":"OpenAI","configured":true}]}"#.utf8)
        let status = try JSONDecoder().decode(TTSStatus.self, from: data)
        #expect(status.enabled && status.providerStates.first?.id == "openai")
    }

    @Test func providers() {
        let provider = TTSProvider(Fixtures.json(#"{"id":"openai","name":"OpenAI","configured":true,"models":["tts-1"],"voices":["alloy","verse"]}"#))
        #expect(provider?.name == "OpenAI" && provider?.models == ["tts-1"] && provider?.voices == ["alloy", "verse"] && provider?.configured == true)
        let bare = TTSProvider(Fixtures.json(#"{"id":"local"}"#))
        #expect(bare?.name == "local" && bare?.configured == false && bare?.models.isEmpty == true && bare?.voices.isEmpty == true)
        #expect(TTSProvider(Fixtures.json(#"{"name":"no id"}"#)) == nil)
    }

    @Test func personas() {
        let persona = TTSPersona(Fixtures.json(#"{"id":"n","label":"N","description":"d","provider":"openai","fallbackPolicy":"x","providers":["openai"]}"#))
        #expect(persona == TTSPersona(id: "n", label: "N", description: "d", provider: "openai"))
        #expect(TTSPersona(Fixtures.json(#"{"label":"no id"}"#)) == nil)
        #expect(TTSPersona(id: "x", label: "").displayName == "x")
    }

    @Test func clipFromSpeakResult() {
        let clip = TTSClip(Fixtures.json(#"{"audioBase64":"AAEC","provider":"openai","outputFormat":"mp3_44100_128","mimeType":"audio/mpeg","fileExtension":"mp3"}"#))
        #expect(clip?.data == Data([0, 1, 2]) && clip?.provider == "openai" && clip?.mimeType == "audio/mpeg" && clip?.fileExtension == "mp3")
        let bare = TTSClip(Fixtures.json(#"{"audioBase64":"AAEC"}"#))
        #expect(bare?.data.count == 3 && bare?.provider == nil && bare?.mimeType == nil)
        #expect(TTSClip(Fixtures.json(#"{"audioBase64":""}"#)) == nil)
        #expect(TTSClip(Fixtures.json(#"{"provider":"openai"}"#)) == nil)
        #expect(TTSClip(Fixtures.json(#"{"audioBase64":"!!!not base64!!!"}"#)) == nil)
    }

    @Test(arguments: [
        (nil as String?, nil as String?, nil as String?, false),
        ("audio/mpeg", "mp3_44100_128", "mp3", false),
        ("audio/wav", "wav", "wav", false),
        ("audio/wav", "pcm_16000", "wav", true),
        ("audio/pcm", nil, nil, true),
        ("audio/L16", nil, nil, true),
        ("audio/l16;rate=24000", nil, nil, true),
        ("audio/x-mulaw", nil, nil, true),
        ("audio/x-alaw", nil, nil, true),
        (nil, "raw-24khz-16bit-mono-pcm", nil, true),
        (nil, "pcm_22050", nil, true),
        (nil, "ulaw_8000", nil, true),
        (nil, "mulaw", nil, true),
        (nil, "opus_48000", "opus", false),
        (nil, nil, "pcm", true),
        (nil, nil, ".raw", true),
        (nil, nil, "mp3", false),
    ])
    func headerless(mime: String?, format: String?, ext: String?, expected: Bool) {
        let clip = TTSClip(data: Data([1]), mimeType: mime, fileExtension: ext)
        var full = clip
        full.outputFormat = format
        #expect(full.isHeaderless == expected)
    }

    @Test(arguments: [
        ("audio/mpeg", nil as String?, "public.mp3"),
        ("audio/wav", nil, "com.microsoft.waveform-audio"),
        (nil, "wav", "com.microsoft.waveform-audio"),
        (nil, "mp3", "public.mp3"),
        ("audio/mp4", nil, "com.apple.m4a-audio"),
        (nil, "caf", "com.apple.coreaudio-format"),
        (nil, "flac", "org.xiph.flac"),
        ("application/octet-stream", nil, nil),
        (nil, nil, nil),
    ])
    func fileTypeHint(mime: String?, ext: String?, expected: String?) {
        #expect(TTSClip(data: Data([1]), mimeType: mime, fileExtension: ext).fileTypeHint == expected)
    }
}
