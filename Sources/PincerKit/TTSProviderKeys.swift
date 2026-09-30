import Foundation

/// The single place that knows where a TTS provider's settings live in the Gateway config. Values are
/// provisional until the upstream research notes confirm them; a correction is a change here only.
public struct TTSProviderKeys: Sendable, Equatable {
    public let provider: String
    public let apiKey: String?
    public let model: String?
    public let voice: String?
    public let voiceSettings: String?
    public let envVar: String?
    /// Equivalent voice key the Gateway also reads (`speakerVoiceId` beats `voiceId` when both exist, so
    /// both are written).
    public let voiceAlias: String?

    public init(provider: String, apiKey: String? = "apiKey", model: String? = "model", voice: String? = "voice",
                voiceSettings: String? = nil, envVar: String? = nil, voiceAlias: String? = nil)
    {
        self.voiceAlias = voiceAlias
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.voiceSettings = voiceSettings
        self.envVar = envVar
    }

    /// Config path of the TTS section.
    public static let configRoot = ["tts"]
    /// Where older Gateways kept it (read only, when `configRoot` is absent).
    public static let legacyConfigRoot = ["messages", "tts"]
    /// Key under the root that holds per-provider objects.
    public static let providersKey = "providers"
    /// `provider` alias of a `{source:"store"}` SecretRef.
    public static let storeSecretProvider = "default"
    /// `provider` alias of a `{source:"env"}` SecretRef.
    public static let envSecretProvider = "default"
    /// Config path (under the root of the config) of literal env vars, for Gateways without a secrets store.
    public static let envVarsPath = ["env", "vars"]

    public static let all: [TTSProviderKeys] = [
        TTSProviderKeys(provider: "elevenlabs", model: "modelId", voice: "voiceId", voiceSettings: "voiceSettings",
                        envVar: "ELEVENLABS_API_KEY", voiceAlias: "speakerVoiceId"),
        TTSProviderKeys(provider: "openai", envVar: "OPENAI_API_KEY", voiceAlias: "speakerVoice"),
        TTSProviderKeys(provider: "google", voice: "voiceName", envVar: "GEMINI_API_KEY", voiceAlias: "speakerVoice"),
        TTSProviderKeys(provider: "minimax", voice: "voiceId", envVar: "MINIMAX_API_KEY", voiceAlias: "speakerVoiceId"),
        TTSProviderKeys(provider: "azure-speech", model: nil, envVar: "AZURE_SPEECH_KEY", voiceAlias: "speakerVoice"),
        TTSProviderKeys(provider: "microsoft", apiKey: nil, model: nil, voiceAlias: "speakerVoice"),
        TTSProviderKeys(provider: "xai", model: nil, voice: "voiceId", envVar: "XAI_API_KEY", voiceAlias: "speakerVoiceId"),
        TTSProviderKeys(provider: "inworld", model: "modelId", voice: "voiceId", envVar: "INWORLD_API_KEY", voiceAlias: "speakerVoiceId"),
        TTSProviderKeys(provider: "gradium", model: nil, voice: "voiceId", envVar: "GRADIUM_API_KEY", voiceAlias: "speakerVoiceId"),
        TTSProviderKeys(provider: "openrouter", envVar: "OPENROUTER_API_KEY", voiceAlias: "speakerVoice"),
        TTSProviderKeys(provider: "volcengine", model: nil, envVar: "VOLCENGINE_TTS_API_KEY", voiceAlias: "speakerVoice"),
        TTSProviderKeys(provider: "xiaomi", envVar: "XIAOMI_API_KEY", voiceAlias: "speakerVoice"),
    ]

    static let aliases = ["azure": "azure-speech", "edge": "microsoft", "mimo": "xiaomi", "doubao": "volcengine", "bytedance": "volcengine"]

    /// Unknown providers get the generic `apiKey` / `model` / `voice` names and `<ID>_API_KEY`.
    public static func forProvider(_ id: String) -> TTSProviderKeys {
        let id = aliases[id.lowercased()] ?? id.lowercased()
        if let known = all.first(where: { $0.provider == id }) { return known }
        let env = id.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return TTSProviderKeys(provider: id, envVar: String(env) + "_API_KEY")
    }

    public static func knownModels(_ provider: String) -> [TTSModelOption] {
        switch provider.lowercased() {
        case "elevenlabs":
            [TTSModelOption(id: "eleven_v4_turbo", name: "Eleven v4 Turbo"), TTSModelOption(id: "eleven_v4", name: "Eleven v4"),
             TTSModelOption(id: "eleven_v3", name: "Eleven v3"), TTSModelOption(id: "eleven_multilingual_v2", name: "Multilingual v2"),
             TTSModelOption(id: "eleven_flash_v2_5", name: "Flash v2.5")]
        default: []
        }
    }

    /// What the Gateway uses when nothing is configured.
    public static func defaultModel(_ provider: String) -> String? {
        provider.lowercased() == "elevenlabs" ? "eleven_multilingual_v2" : nil
    }

    public static func defaultVoice(_ provider: String) -> String? {
        provider.lowercased() == "elevenlabs" ? "pMsXgVXv3BLzUgSXRplE" : nil
    }

    /// Known models, then any `tts.providers` model ids not already listed.
    static func models(_ provider: String, advertised: [String]) -> [TTSModelOption] {
        var options = knownModels(provider)
        for id in advertised where !options.contains(where: { $0.id == id }) { options.append(TTSModelOption(id: id, name: id)) }
        return options
    }
}

public struct TTSModelOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct TTSVoiceSettings: Sendable, Equatable {
    public var stability: Double
    public var similarityBoost: Double
    public var style: Double
    public var useSpeakerBoost: Bool
    public var speed: Double

    public init(stability: Double, similarityBoost: Double, style: Double, useSpeakerBoost: Bool, speed: Double) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
        self.speed = speed
    }

    public static let elevenLabsDefault = TTSVoiceSettings(stability: 0.5, similarityBoost: 0.75, style: 0, useSpeakerBoost: true, speed: 1)

    var json: JSONValue {
        [
            "stability": .number(stability), "similarityBoost": .number(similarityBoost), "style": .number(style),
            "useSpeakerBoost": .bool(useSpeakerBoost), "speed": .number(speed),
        ]
    }

    init(json: JSONValue) {
        let d = Self.elevenLabsDefault
        self.init(stability: json["stability"]?.double ?? d.stability, similarityBoost: json["similarityBoost"]?.double ?? d.similarityBoost,
                  style: json["style"]?.double ?? d.style, useSpeakerBoost: json["useSpeakerBoost"]?.bool ?? d.useSpeakerBoost,
                  speed: json["speed"]?.double ?? d.speed)
    }
}
