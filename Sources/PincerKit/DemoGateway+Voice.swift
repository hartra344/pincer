import Foundation

/// Simulated text-to-speech state (`tts.*`): two providers, two personas, gateway auto-TTS off.
struct DemoVoiceState {
    var enabled = false
    var provider = "openai"
    var persona: String?
}

extension DemoGateway {
    static let voiceMethods = [
        "tts.status", "tts.providers", "tts.personas", "tts.enable", "tts.disable",
        "tts.setProvider", "tts.setPersona", "tts.convert", "tts.speak",
    ]

    private static let voiceProviders: [(id: String, name: String, configured: Bool, models: [String], voices: [String])] = [
        ("openai", "OpenAI", true, ["gpt-4o-mini-tts", "tts-1"], ["alloy", "verse"]),
        ("elevenlabs", "ElevenLabs", false, ["eleven_multilingual_v2"], ["rachel"]),
    ]
    private static let voicePersonas: [(id: String, label: String, description: String)] = [
        ("narrator", "Narrator", "Warm and unhurried, like an audiobook."),
        ("concise", "Concise", "Brisk and to the point."),
    ]

    private static var voicePersonaJSON: [JSONValue] {
        self.voicePersonas.map { ["id": .string($0.id), "label": .string($0.label), "description": .string($0.description),
                                  "provider": "openai", "providers": ["openai"]] }
    }

    func handleVoice(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "tts.status":
            let states: [JSONValue] = Self.voiceProviders.map {
                ["id": .string($0.id), "label": .string($0.name), "configured": .bool($0.configured)]
            }
            return ["enabled": .bool(self.voice.enabled), "auto": self.voice.enabled ? "always" : "off",
                    "provider": .string(self.voice.provider), "persona": JSONValue(self.voice.persona),
                    "personas": .array(Self.voicePersonaJSON), "fallbackProvider": .null, "fallbackProviders": [],
                    "prefsPath": "~/.openclaw/settings/tts.json", "providerStates": .array(states)]
        case "tts.providers":
            let list: [JSONValue] = Self.voiceProviders.map {
                ["id": .string($0.id), "name": .string($0.name), "configured": .bool($0.configured),
                 "models": JSONValue($0.models), "voices": JSONValue($0.voices)]
            }
            return ["providers": .array(list), "active": .string(self.voice.provider)]
        case "tts.personas":
            return ["active": JSONValue(self.voice.persona), "personas": .array(Self.voicePersonaJSON)]
        case "tts.enable", "tts.disable":
            self.voice.enabled = method == "tts.enable"
            return ["enabled": .bool(self.voice.enabled)]
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
            } else if Self.voicePersonas.contains(where: { $0.id == id }) {
                self.voice.persona = id
            } else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Unknown persona \"\(id)\".", details: nil)
            }
            return ["persona": JSONValue(self.voice.persona)]
        case "tts.convert":
            guard let text = params["text"]?.text, !text.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "tts.convert requires text", details: nil)
            }
            return ["audioPath": "/tmp/openclaw/tts-demo.mp3", "provider": .string(self.voice.provider),
                    "outputFormat": "mp3", "voiceCompatible": false]
        case "tts.speak":
            guard let text = params["text"]?.text, !text.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "tts.speak requires text", details: nil)
            }
            guard text.count <= 4096 else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "text too long", details: nil)
            }
            return ["audioBase64": .string(Self.demoTone().base64EncodedString()), "provider": .string(self.voice.provider),
                    "outputFormat": "wav", "mimeType": "audio/wav", "fileExtension": "wav"]
        default:
            return nil
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
