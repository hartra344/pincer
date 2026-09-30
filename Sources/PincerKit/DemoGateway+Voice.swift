import Foundation

/// Simulated text-to-speech state (`tts.*`): two providers, two personas, gateway auto-TTS off.
struct DemoVoiceState {
    struct SecretEntry {
        var kind: String
        var value: String
        var allowedHosts: [String]
        var createdAtMs: Double
        var updatedAtMs: Double
    }

    /// Local prefs (`/tts` settings): a provider chosen with `tts.setProvider`, a persona and an auto mode written by
    /// `tts.enable` / `tts.disable`. Config supplies the defaults, as upstream's `resolveTtsSettingsSnapshot`.
    var provider: String?
    var persona: String?
    var auto: String?
    /// The demo's `secrets.store`, keyed by env-style name.
    var secrets: [String: SecretEntry] = [:]

    static let secretNamePattern = #"^[A-Z][A-Z0-9_]{0,127}$"#

    /// The TTS section of the config as `config.get` first shows it: OpenAI configured, ElevenLabs without a key.
    static var seedTTSConfig: JSONValue {
        let section: JSONValue = [
            "providers": ["openai": ["model": "gpt-4o-mini-tts", "voice": "alloy"]],
            "personas": [
                "narrator": ["label": "Narrator", "description": "Warm and unhurried, like an audiobook.", "provider": "openai",
                             "providers": ["openai": [:]]],
                "concise": ["label": "Concise", "description": "Brisk and to the point.", "provider": "openai",
                            "providers": ["openai": [:]]],
            ],
        ]
        let tts = TTSProviderKeys.configRoot.reversed().reduce(section) { [$1: $0] }
        // PINCER_DEMO_TTS_AUTO=inbound (off|always|inbound|tagged) seeds upstream's config default `messages.tts.auto`.
        guard let auto = ProcessInfo.processInfo.environment["PINCER_DEMO_TTS_AUTO"], ["off", "always", "inbound", "tagged"].contains(auto),
              case var .object(root) = tts else { return tts }
        root["messages"] = ["tts": ["auto": .string(auto)]]
        return .object(root)
    }

    /// Paths `config.get` redacts: an inline `apiKey`, a SecretRef's `id` and `env.vars.*_API_KEY`.
    static func isAPIKeyPath(_ path: [String]) -> Bool {
        if path.count == 3, path[0] == "env", path[1] == "vars", path[2].hasSuffix("_API_KEY") { return true }
        let root = TTSProviderKeys.configRoot
        guard path.count >= root.count + 3, Array(path.prefix(root.count)) == root,
              path[root.count] == TTSProviderKeys.providersKey else { return false }
        let rest = path.dropFirst(root.count + 2)
        return rest.elementsEqual(["apiKey"]) || rest.elementsEqual(["apiKey", "id"])
    }
}

extension DemoGateway {
    static let voiceMethods = [
        "tts.status", "tts.providers", "tts.personas", "tts.enable", "tts.disable",
        "tts.setProvider", "tts.setPersona", "tts.convert", "tts.speak",
        "secrets.store.set", "secrets.store.list", "secrets.store.delete",
    ]

    private static let voiceProviders: [(id: String, name: String, models: [String], voices: [String])] = [
        ("openai", "OpenAI", ["gpt-4o-mini-tts", "tts-1"], ["alloy", "verse"]),
        ("elevenlabs", "ElevenLabs", ["eleven_v3", "eleven_multilingual_v2", "eleven_flash_v2_5", "eleven_flash_v2",
                                      "eleven_turbo_v2_5", "eleven_monolingual_v1"], ["pMsXgVXv3BLzUgSXRplE"]),
    ]

    /// The account voices the demo lists for ElevenLabs; previews are offline (a `data:` WAV chime).
    static let demoElevenLabsVoices: [ElevenLabsVoice] = {
        let preview = URL(string: "data:audio/wav;base64," + DemoGateway.demoTone().base64EncodedString())
        return [("21m00Tcm4TlvDq8ikWAM", "Rachel"), ("pNInz6obpgDQGcFmaJgB", "Adam"),
                ("EXAVITQu4vr4xnAVfSq9", "Bella"), ("ErXwobaYiN019PkySvjV", "Antoni")].map {
            ElevenLabsVoice(id: $0.0, name: $0.1, category: "premade", previewURL: preview)
        }
    }()

    /// Drop-in for `GatewayVoiceModel.voiceLister` in the demo: no network; a key starting with "bad" is refused.
    static let demoVoiceLister: @MainActor (String?) async throws -> [ElevenLabsVoice] = { key in
        guard let key, !key.isEmpty else { throw TTSSetupError.needsKey }
        if DemoGateway.isBadElevenLabsKey(key) {
            throw GatewayError.rpc(code: "UNAVAILABLE", message: DemoGateway.elevenLabsInvalidKeyMessage, details: nil)
        }
        return DemoGateway.demoElevenLabsVoices
    }

    static let elevenLabsInvalidKeyMessage = "ElevenLabs API error (401): invalid_api_key: Invalid API key"

    static func isBadElevenLabsKey(_ key: String) -> Bool {
        key.hasPrefix("bad") || key == "sk_invalid"
    }

    private func voiceProviderConfig(_ id: String) -> JSONValue? {
        var node: JSONValue? = self.mcp.config
        for key in TTSProviderKeys.configRoot + [TTSProviderKeys.providersKey, id] { node = node?[key] }
        return node
    }

    /// The API key a provider would use, resolving a literal, a `store` SecretRef or an `env` SecretRef.
    private func voiceKey(_ id: String) -> String? {
        if id == "openai" { return "sk-demo" }
        guard let value = self.voiceProviderConfig(id)?["apiKey"] else { return nil }
        if let literal = value.string { return literal.isEmpty || literal == DemoMCPState.redacted ? nil : literal }
        guard let ref = value.object, let refID = ref["id"]?.string else { return nil }
        switch ref["source"]?.string {
        case "store": return self.voice.secrets[refID]?.value
        case "env": return self.mcp.config["env"]?["vars"]?[refID]?.string
        default: return nil
        }
    }

    private func voiceConfigured(_ id: String) -> Bool {
        self.voiceKey(id) != nil
    }

    private func voiceRPC(_ code: String, _ message: String) -> GatewayError {
        GatewayError.rpc(code: code, message: message, details: nil)
    }

    /// One provider's attempt, worded as the provider's error (`ElevenLabs API error (401): …`) or "not configured".
    private func voiceAttempt(_ provider: String, model explicitModel: String?, voice explicitVoice: String?) -> String? {
        guard self.voiceConfigured(provider) else { return "not configured" }
        guard provider == "elevenlabs" else { return nil }
        if let key = self.voiceKey(provider), Self.isBadElevenLabsKey(key) { return Self.elevenLabsInvalidKeyMessage }
        let effective = Self.elevenLabsEffective(self.voiceProviderConfig(provider))
        let model = Self.normalizeElevenLabsModel(explicitModel) ?? effective.modelId
        let voice = explicitVoice ?? effective.voiceId
        if !model.hasPrefix("eleven_") || model == "eleven_bogus" {
            return "ElevenLabs API error (400): model_id_does_not_exist: Model with ID \(model) does not exist"
        }
        if voice.hasPrefix("bogus") {
            return "ElevenLabs API error (404): voice_not_found: A voice with the voice_id \(voice) was not found."
        }
        return nil
    }

    static let elevenLabsDefaultVoiceID = "pMsXgVXv3BLzUgSXRplE"
    static let elevenLabsDefaultModelID = "eleven_multilingual_v2"

    private static func nonEmpty(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func normalizeElevenLabsModel(_ value: String?) -> String? {
        switch value {
        case "eleven_turbo_v2_5": "eleven_flash_v2_5"
        case "eleven_turbo_v2": "eleven_flash_v2"
        default: value
        }
    }

    /// What ElevenLabs effectively uses for a provider config node (upstream `withSpeakerSelectionCompat` +
    /// `normalizeElevenLabsProviderConfig`): voice is `speakerVoiceId`, else `voiceId`, else the default; the model is
    /// `modelId` only, and a `model` key is never read (`ignoredModel`).
    static func elevenLabsEffective(_ node: JSONValue?) -> (voiceId: String, modelId: String, ignoredModel: String?) {
        let modelId = self.normalizeElevenLabsModel(self.nonEmpty(node?["modelId"]))
        return (self.nonEmpty(node?["speakerVoiceId"]) ?? self.nonEmpty(node?["voiceId"]) ?? self.elevenLabsDefaultVoiceID,
                modelId ?? self.elevenLabsDefaultModelID,
                self.nonEmpty(node?["modelId"]) == nil ? self.nonEmpty(node?["model"]) : nil)
    }

    /// Mirrors upstream `executeTtsProviderAttempts`: the primary provider is tried first, then (unless
    /// `fallback` is false, as for an explicit provider/model/voice) every other provider. The provider that
    /// succeeded is returned; when none does the errors are joined as `TTS conversion failed: p: msg; q: msg`.
    private func voiceSynthesize(provider primary: String, model explicitModel: String?, voice explicitVoice: String? = nil, fallback: Bool) throws -> String {
        let order = fallback ? [primary] + Self.voiceProviders.map(\.id).filter { $0 != primary } : [primary]
        var errors: [String] = []
        for provider in order {
            guard let failure = self.voiceAttempt(provider, model: provider == primary ? explicitModel : nil,
                                                  voice: provider == primary ? explicitVoice : nil) else { return provider }
            errors.append("\(provider): \(failure)")
        }
        throw self.voiceRPC("UNAVAILABLE", "TTS conversion failed: " + errors.joined(separator: "; "))
    }
    /// The TTS section of the live config, falling back to upstream's `messages.tts`.
    private func voiceConfigNode(_ key: String) -> JSONValue? {
        for root in [TTSProviderKeys.configRoot, TTSProviderKeys.legacyConfigRoot] {
            var node: JSONValue? = self.mcp.config
            for part in root { node = node?[part] }
            if let value = node?[key] { return value }
        }
        return nil
    }

    private struct VoicePersona {
        var id: String
        var json: JSONValue
        var provider: String?
    }

    private var voicePersonas: [VoicePersona] {
        (self.voiceConfigNode("personas")?.object ?? [:]).sorted { $0.key < $1.key }.compactMap { id, node in
            guard node.object != nil else { return nil }
            let provider = Self.nonEmpty(node["provider"])?.lowercased()
            var json: [String: JSONValue] = ["id": .string(id.lowercased()), "providers": .array((node["providers"]?.object ?? [:]).keys.sorted().map { .string($0) })]
            for key in ["label", "description", "fallbackPolicy"] { if let value = node[key], value != .null { json[key] = value } }
            if let provider { json["provider"] = .string(provider) }
            return VoicePersona(id: id.lowercased(), json: .object(json), provider: provider)
        }
    }

    private var voicePersonaJSON: [JSONValue] { self.voicePersonas.map(\.json) }

    private var activeVoicePersona: VoicePersona? { self.voicePersonas.first { $0.id == self.voice.persona } }

    /// prefs provider, else the active persona's, else config `provider`, else openai.
    private var voiceProvider: String {
        self.voice.provider ?? self.activeVoicePersona?.provider
            ?? Self.nonEmpty(self.voiceConfigNode("provider"))?.lowercased() ?? "openai"
    }

    /// prefs auto, else config `auto` (`messages.tts.auto`), else off.
    private var voiceAuto: String {
        let modes = ["off", "always", "inbound", "tagged"]
        if let auto = self.voice.auto { return auto }
        if let auto = Self.nonEmpty(self.voiceConfigNode("auto"))?.lowercased(), modes.contains(auto) { return auto }
        return "off"
    }

    func handleVoice(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "tts.status":
            let states: [JSONValue] = Self.voiceProviders.map {
                ["id": .string($0.id), "label": .string($0.name), "configured": .bool(self.voiceConfigured($0.id))]
            }
            let auto = self.voiceAuto
            let provider = self.voiceProvider
            let fallbacks = Self.voiceProviders.map(\.id).filter { $0 != provider && self.voiceConfigured($0) }
            return ["enabled": .bool(auto != "off"), "auto": .string(auto),
                    "provider": .string(provider), "persona": JSONValue(self.activeVoicePersona?.id),
                    "personas": .array(self.voicePersonaJSON.map { persona in
                        var object = persona.object ?? [:]
                        object["providers"] = nil
                        object["fallbackPolicy"] = nil
                        return .object(object)
                    }), "fallbackProvider": JSONValue(fallbacks.first), "fallbackProviders": JSONValue(fallbacks), 
                    "prefsPath": "~/.openclaw/settings/tts.json", "providerStates": .array(states)]
        case "tts.providers":
            let list: [JSONValue] = Self.voiceProviders.map {
                ["id": .string($0.id), "name": .string($0.name), "configured": .bool(self.voiceConfigured($0.id)),
                 "models": JSONValue($0.models), "voices": JSONValue($0.voices)]
            }
            return ["providers": .array(list), "active": .string(self.voiceProvider)]
        case "tts.personas":
            return ["active": JSONValue(self.activeVoicePersona?.id), "personas": .array(self.voicePersonaJSON)]
        case "tts.enable", "tts.disable":
            self.voice.auto = method == "tts.enable" ? "always" : "off"
            return ["enabled": .bool(method == "tts.enable")]
        case "tts.setProvider":
            guard let id = params["provider"]?.text, Self.voiceProviders.contains(where: { $0.id == id }) else {
                let given = params["provider"]?.text ?? ""
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Invalid provider. Use one of: openai, elevenlabs. (got \"\(given)\")", details: nil)
            }
            self.voice.provider = id
            return ["provider": .string(id)]
        case "tts.setPersona":
            let id = (params["persona"]?.text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if ["", "off", "none", "default"].contains(id) {
                self.voice.persona = nil
            } else if self.voicePersonas.contains(where: { $0.id == id }) {
                self.voice.persona = id
            } else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Unknown persona \"\(id)\".", details: nil)
            }
            return ["persona": JSONValue(self.activeVoicePersona?.id)]
        case "tts.convert":
            guard let text = params["text"]?.text, !text.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "tts.convert requires text", details: nil)
            }
            let requested = params["provider"]?.text
            let used = try self.voiceSynthesize(provider: requested ?? self.voiceProvider,
                                                model: params["modelId"]?.text, voice: params["voiceId"]?.text,
                                                fallback: [requested, params["modelId"]?.text, params["voiceId"]?.text].allSatisfy { $0 == nil })
            return ["audioPath": "/tmp/openclaw/tts-demo.mp3", "provider": .string(used),
                    "outputFormat": "mp3", "voiceCompatible": false]
        case "tts.speak":
            guard let text = params["text"]?.text, !text.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "tts.speak requires text", details: nil)
            }
            guard text.count <= 4096 else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "text too long", details: nil)
            }
            let used = try self.voiceSynthesize(provider: self.voiceProvider, model: nil, fallback: true)
            return ["audioBase64": .string(Self.demoTone().base64EncodedString()), "provider": .string(used),
                    "outputFormat": "wav", "mimeType": "audio/wav", "fileExtension": "wav"]
        case "secrets.store.list", "secrets.store.set", "secrets.store.delete":
            return try self.handleSecretsStore(method, params)
        default:
            return nil
        }
    }

    private func handleSecretsStore(_ method: String, _ params: JSONValue) throws -> JSONValue {
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        switch method {
        case "secrets.store.list":
            let entries: [JSONValue] = self.voice.secrets.sorted { $0.key < $1.key }.map { name, entry in
                var object: [String: JSONValue] = [
                    "name": .string(name), "scopeKind": "team", "scopeId": "", "kind": .string(entry.kind),
                    "createdAtMs": .number(entry.createdAtMs), "updatedAtMs": .number(entry.updatedAtMs),
                    "updatedBy": "Demo",
                ]
                if entry.kind == "env" { object["value"] = .string(entry.value) } else {
                    object["allowedHosts"] = JSONValue(entry.allowedHosts)
                }
                return .object(object)
            }
            return ["entries": .array(entries)]
        case "secrets.store.set":
            let name = params["name"]?.string ?? ""
            let value = params["value"]?.string ?? ""
            let kind = params["kind"]?.string ?? "secret"
            guard name.range(of: DemoVoiceState.secretNamePattern, options: .regularExpression) != nil else {
                throw self.voiceRPC("INVALID_REQUEST", "Secret store name must match /^[A-Z][A-Z0-9_]{0,127}$/.")
            }
            guard ["secret", "env"].contains(kind) else {
                throw self.voiceRPC("INVALID_REQUEST", "invalid secrets.store.set params: kind must be \"secret\" or \"env\"")
            }
            if value == DemoMCPState.redacted {
                throw self.voiceRPC("INVALID_REQUEST", "Secret store entry \"\(name)\" contains a redaction placeholder. Supply a real value or leave the field unchanged.")
            }
            if kind == "secret", value.isEmpty {
                throw self.voiceRPC("INVALID_REQUEST", "Secret store value is empty. Secret entries require a value; check the command that produced it.")
            }
            let hosts = (params["allowedHosts"]?.array ?? []).compactMap(\.string)
            let created = self.voice.secrets[name]?.createdAtMs ?? now
            self.voice.secrets[name] = DemoVoiceState.SecretEntry(kind: kind, value: value, allowedHosts: Array(Set(hosts)).sorted(),
                                                                  createdAtMs: created, updatedAtMs: now)
            return ["ok": true, "reloaded": true]
        default:
            guard let name = params["name"]?.string, !name.isEmpty else {
                throw self.voiceRPC("INVALID_REQUEST", "invalid secrets.store.delete params: name is required")
            }
            self.voice.secrets[name] = nil
            return ["ok": true, "reloaded": true]
        }
    }

    /// A 0.6 s gentle two-note chime as a 16-bit mono 22.05 kHz WAV.
    static func demoTone() -> Data {
        let rate = 22050
        let count = rate * 6 / 10
        var samples = Data(capacity: count * 2)
        for index in 0 ..< count {
            let t = Double(index) / Double(rate)
            let frequency = t < 0.3 ? 660.0 : 880.0
            let envelope = min(1, Double(count - index) / Double(rate / 5)) * min(1, t * 100)
            let value = Int16(sin(2 * .pi * frequency * t) * 0.2 * envelope * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + samples.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        wav.append(contentsOf: Array("data".utf8)); put32(UInt32(samples.count))
        wav.append(samples)
        return wav
    }
}
