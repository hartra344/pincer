import Testing
@testable import PincerKit

@Suite("TTS provider keys")
struct TTSProviderKeysTests {
    @Test func configRootIsTopLevelTTS() {
        #expect(TTSProviderKeys.configRoot == ["tts"], "upstream reads cfg.tts; messages.tts is legacy")
    }

    @Test func elevenLabsUsesTheKeysTheProviderReads() {
        let keys = TTSProviderKeys.forProvider("elevenlabs")
        #expect(keys.provider == "elevenlabs" && keys.apiKey == "apiKey" && keys.model == "modelId" && keys.voice == "voiceId"
                && keys.voiceSettings == "voiceSettings" && keys.envVar == "ELEVENLABS_API_KEY")
    }

    @Test func lookupIsCaseInsensitive() {
        #expect(TTSProviderKeys.forProvider("ElevenLabs") == TTSProviderKeys.forProvider("elevenlabs"))
    }

    @Test func openAIUsesModelAndVoice() {
        let keys = TTSProviderKeys.forProvider("openai")
        #expect(keys.apiKey == "apiKey" && keys.model == "model" && keys.voice == "voice" && keys.voiceSettings == nil
                && keys.envVar == "OPENAI_API_KEY")
    }

    @Test func microsoftHasNoKey() {
        #expect(TTSProviderKeys.forProvider("microsoft").apiKey == nil)
    }

    @Test func unknownProviderIsGeneric() {
        let keys = TTSProviderKeys.forProvider("acme-tts")
        #expect(keys.provider == "acme-tts" && keys.apiKey == "apiKey" && keys.model == "model" && keys.voice == "voice"
                && keys.voiceSettings == nil && keys.envVar == "ACME_TTS_API_KEY")
    }

    @Test func everyKnownProviderIsListedOnce() {
        let ids = TTSProviderKeys.all.map(\.provider)
        #expect(Set(ids).count == ids.count && ids.contains("elevenlabs") && ids.contains("openai"))
    }

    @Test func elevenLabsModelsInOrder() {
        #expect(TTSProviderKeys.knownModels("elevenlabs").map(\.id)
                == ["eleven_v4_turbo", "eleven_v4", "eleven_v3", "eleven_multilingual_v2", "eleven_flash_v2_5"])
        #expect(TTSProviderKeys.knownModels("elevenlabs").first?.name == "Eleven v4 Turbo")
        #expect(TTSProviderKeys.knownModels("openai").isEmpty)
    }

    @Test func voiceSettingsDefaults() {
        let d = TTSVoiceSettings.elevenLabsDefault
        #expect(d.stability == 0.5 && d.similarityBoost == 0.75 && d.style == 0 && d.useSpeakerBoost && d.speed == 1)
    }
}
