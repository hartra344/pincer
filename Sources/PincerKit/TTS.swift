import Foundation

// Gateway text-to-speech models (`tts.status`, `tts.providers`, `tts.personas`, `tts.speak`).
// Parsing is tolerant: optional fields may be missing and unknown fields are ignored.
// Each model is Decodable and also builds from a `JSONValue` with `init?(_:)`.

public struct TTSProviderState: Hashable, Sendable, Identifiable, Decodable {
    public var id: String
    public var label: String
    public var configured: Bool

    public init(id: String, label: String, configured: Bool) {
        self.id = id
        self.label = label
        self.configured = configured
    }

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text, !id.isEmpty else { return nil }
        self.init(id: id, label: json["label"]?.text ?? id, configured: json["configured"]?.bool ?? false)
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let value = Self(json) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "missing id") }
        self = value
    }
}

public struct TTSProvider: Hashable, Sendable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var configured: Bool
    public var models: [String]
    public var voices: [String]

    public init(id: String, name: String, configured: Bool, models: [String] = [], voices: [String] = []) {
        self.id = id
        self.name = name
        self.configured = configured
        self.models = models
        self.voices = voices
    }

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"]?.text ?? id, configured: json["configured"]?.bool ?? false,
                  models: json["models"]?.array?.compactMap(\.text) ?? [],
                  voices: json["voices"]?.array?.compactMap(\.text) ?? [])
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let value = Self(json) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "missing id") }
        self = value
    }
}

public struct TTSPersona: Hashable, Sendable, Identifiable, Decodable {
    public var id: String
    public var label: String?
    public var description: String?
    public var provider: String?

    public init(id: String, label: String? = nil, description: String? = nil, provider: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.provider = provider
    }

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text, !id.isEmpty else { return nil }
        self.init(id: id, label: json["label"]?.text, description: json["description"]?.text, provider: json["provider"]?.text)
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let value = Self(json) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "missing id") }
        self = value
    }

    /// The label, else the id.
    public var displayName: String { self.label.flatMap { $0.isEmpty ? nil : $0 } ?? self.id }
}

public struct TTSStatus: Hashable, Sendable, Decodable {
    public var enabled: Bool
    /// "off", "always", "inbound" or "tagged".
    public var auto: String
    public var provider: String
    public var persona: String?
    public var personas: [TTSPersona]
    public var fallbackProviders: [String]
    public var providerStates: [TTSProviderState]

    public init(enabled: Bool, auto: String = "off", provider: String, persona: String? = nil, personas: [TTSPersona] = [],
                fallbackProviders: [String] = [], providerStates: [TTSProviderState] = [])
    {
        self.enabled = enabled
        self.auto = auto
        self.provider = provider
        self.persona = persona
        self.personas = personas
        self.fallbackProviders = fallbackProviders
        self.providerStates = providerStates
    }

    public init?(_ json: JSONValue) {
        guard case .object = json else { return nil }
        let persona = json["persona"]?.text
        self.init(enabled: json["enabled"]?.bool ?? false, auto: json["auto"]?.text ?? "off",
                  provider: json["provider"]?.text ?? "",
                  persona: persona?.isEmpty == false ? persona : nil,
                  personas: json["personas"]?.array?.compactMap(TTSPersona.init) ?? [],
                  fallbackProviders: json["fallbackProviders"]?.array?.compactMap(\.text) ?? [],
                  providerStates: json["providerStates"]?.array?.compactMap(TTSProviderState.init) ?? [])
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let value = Self(json) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "not an object") }
        self = value
    }

    /// Whether any provider can synthesize. False only when states are listed and none is configured.
    public var hasConfiguredProvider: Bool {
        self.providerStates.isEmpty || self.providerStates.contains { $0.configured }
    }
}

/// One `tts.speak` result: encoded audio for the client to play.
public struct TTSClip: Hashable, Sendable {
    public var data: Data
    public var provider: String?
    public var outputFormat: String?
    public var mimeType: String?
    public var fileExtension: String?

    public init(data: Data, provider: String? = nil, outputFormat: String? = nil, mimeType: String? = nil, fileExtension: String? = nil) {
        self.data = data
        self.provider = provider
        self.outputFormat = outputFormat
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }

    /// nil when `audioBase64` is missing, empty or not base64.
    public init?(_ json: JSONValue) {
        guard let base64 = json["audioBase64"]?.text, !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty
        else { return nil }
        self.init(data: data, provider: json["provider"]?.text, outputFormat: json["outputFormat"]?.text,
                  mimeType: json["mimeType"]?.text, fileExtension: json["fileExtension"]?.text)
    }

    /// Raw sample formats have no container header, so AVAudioPlayer can't decode them.
    public var isHeaderless: Bool {
        let mime = (self.mimeType ?? "").lowercased()
        if mime == "audio/pcm" || mime == "audio/l16" || mime == "audio/basic" || mime.hasPrefix("audio/l16")
            || mime.hasPrefix("audio/pcm") || mime == "audio/x-mulaw" || mime == "audio/x-alaw" { return true }
        let format = (self.outputFormat ?? "").lowercased()
        for prefix in ["raw-", "raw_", "pcm_", "pcm-", "ulaw", "mulaw", "alaw", "mu-law", "mu_law"] where format.hasPrefix(prefix) {
            return true
        }
        if ["pcm", "raw", "mulaw", "alaw", "ulaw", "l16"].contains(format) { return true }
        let ext = (self.fileExtension ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["pcm", "raw", "mulaw", "alaw", "ulaw"].contains(ext)
    }

    /// An `AVFileType` raw value for AVAudioPlayer, from the MIME type or extension.
    public var fileTypeHint: String? {
        let mime = (self.mimeType ?? "").lowercased()
        let ext = (self.fileExtension ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch true {
        case mime.contains("mpeg") || mime.contains("mp3") || ext == "mp3": return "public.mp3"
        case mime.contains("wav") || ext == "wav" || ext == "wave": return "com.microsoft.waveform-audio"
        case mime.contains("aiff") || ext == "aiff" || ext == "aif": return "public.aiff-audio"
        case mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") || ext == "m4a" || ext == "mp4" || ext == "aac":
            return "com.apple.m4a-audio"
        case mime.contains("caf") || ext == "caf": return "com.apple.coreaudio-format"
        case mime.contains("flac") || ext == "flac": return "org.xiph.flac"
        default: return nil
        }
    }
}
