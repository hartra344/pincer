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
                && keys.voiceAlias == "speakerVoiceId" && keys.voiceSettings == "voiceSettings" && keys.envVar == "ELEVENLABS_API_KEY")
    }

    @Test func lookupIsCaseInsensitive() {
        #expect(TTSProviderKeys.forProvider("ElevenLabs") == TTSProviderKeys.forProvider("elevenlabs"))
    }

    @Test func openAIUsesModelAndVoice() {
        let keys = TTSProviderKeys.forProvider("openai")
        #expect(keys.apiKey == "apiKey" && keys.model == "model" && keys.voice == "voice" && keys.voiceSettings == nil
                && keys.envVar == "OPENAI_API_KEY")
    }

    @Test func perProviderTable() {
        let table: [(String, String?, String?, String?)] = [
            ("google", "model", "voiceName", "GEMINI_API_KEY"), ("minimax", "model", "voiceId", "MINIMAX_API_KEY"),
            ("azure-speech", nil, "voice", "AZURE_SPEECH_KEY"), ("xai", nil, "voiceId", "XAI_API_KEY"),
            ("inworld", "modelId", "voiceId", "INWORLD_API_KEY"), ("gradium", nil, "voiceId", "GRADIUM_API_KEY"),
            ("openrouter", "model", "voice", "OPENROUTER_API_KEY"), ("volcengine", nil, "voice", "VOLCENGINE_TTS_API_KEY"),
            ("xiaomi", "model", "voice", "XIAOMI_API_KEY"),
        ]
        for (id, model, voice, env) in table {
            let k = TTSProviderKeys.forProvider(id)
            #expect(k.model == model && k.voice == voice && k.envVar == env, "\(id)")
        }
        #expect(TTSProviderKeys.forProvider("azure").provider == "azure-speech")
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
