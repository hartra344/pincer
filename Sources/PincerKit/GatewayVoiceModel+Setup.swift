import Foundation

// Gateway Voice setup (#459): provider badges, API key / model / voice / voice settings written through
// `config.patch` (and `secrets.store.set`), a Test voice call, and the effective-config summary.

public enum TTSProviderBadge: Equatable, Sendable {
    case ready
    case needsKey
    case error(String)
}

public struct TTSProviderSetup: Equatable, Sendable {
    public enum KeySource: Equatable, Sendable {
        case none
        /// A plaintext value the Gateway returned.
        case inline
        case secretRef(source: String, provider: String, id: String)
        /// Present, but the Gateway hid it.
        case redacted
    }

    public var keySource: KeySource
    public var model: String?
    public var voice: String?
    public var voiceSettings: TTSVoiceSettings?

    public init(keySource: KeySource = .none, model: String? = nil, voice: String? = nil, voiceSettings: TTSVoiceSettings? = nil) {
        self.keySource = keySource
        self.model = model
        self.voice = voice
        self.voiceSettings = voiceSettings
    }
}

public enum TTSFallbackReason: Equatable, Sendable {
    case noWritePermission
    case notConfigured(provider: String)
    case keyNotResolving
    case modelRejected(String)
    case gatewayUnsupported
    case deviceOnlySetting
    case other(String)

    public var message: String {
        switch self {
        case .noWritePermission: L("This device doesn't have write access to the Gateway voice.")
        case let .notConfigured(provider): String(format: L("%@ isn't configured on the Gateway."), provider)
        case .keyNotResolving: L("The Gateway can't read the saved API key.")
        case let .modelRejected(detail): String(format: L("The provider rejected the model or voice: %@"), detail)
        case .gatewayUnsupported: L("This Gateway doesn't support voice.")
        case .deviceOnlySetting: L("Read Aloud is set to use this device's voice.")
        case let .other(detail): detail
        }
    }
}

public struct TTSTestResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case success
        case failed(String)
        case fellBack(to: String, reason: TTSFallbackReason)
    }

    public let outcome: Outcome
    public let provider: String?
    public let model: String?
    public let voiceName: String?
    public let durationMs: Int
    public let clip: TTSClip?

    public init(outcome: Outcome, provider: String? = nil, model: String? = nil, voiceName: String? = nil, durationMs: Int = 0, clip: TTSClip? = nil) {
        self.outcome = outcome
        self.provider = provider
        self.model = model
        self.voiceName = voiceName
        self.durationMs = durationMs
        self.clip = clip
    }

    /// "ElevenLabs · Eleven v4 Turbo · Rachel · 820 ms"; the error text when it failed.
    public var summary: String {
        switch self.outcome {
        case let .failed(message): return message
        case .success, .fellBack:
            let parts = [self.provider, self.model, self.voiceName].compactMap { $0 }.filter { !$0.isEmpty }
            return (parts + ["\(self.durationMs) ms"]).joined(separator: " · ")
        }
    }
}

public struct TTSEffectiveRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    /// "Gateway config", "Local /tts prefs", "Persona <x>" or "Default".
    public let source: String
    public var id: String { self.label }

    public init(label: String, value: String, source: String) {
        self.label = label
        self.value = value
        self.source = source
    }
}

public enum ReadAloudGatewaySummary: Equatable, Sendable {
    case automatic(provider: String, model: String?, gateway: String)
    case fallback(TTSFallbackReason)
}

public struct ElevenLabsVoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String?
    public let previewURL: URL?

    public init(id: String, name: String, category: String? = nil, previewURL: URL? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.previewURL = previewURL
    }
}

public enum TTSSetupError: Error, LocalizedError, Equatable {
    case needsKey
    case invalidKey
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .needsKey: L("Paste your ElevenLabs API key to browse voices.")
        case .invalidKey: L("ElevenLabs rejected that API key.")
        case let .failed(message): message
        }
    }
}

extension GatewayVoiceModel {
    public static let configGetMethod = "config.get"
    public static let configPatchMethod = "config.patch"
    public static let secretsSetMethod = "secrets.store.set"
    public static let convertMethod = "tts.convert"

    // MARK: Permissions

    /// `config.patch` and `secrets.store.*` need `operator.admin`.
    public var canConfigure: Bool {
        if self.allowsWritesWithoutAdmin { return true }
        return self.scopes().contains(GatewayConnection.adminScope)
    }

    public var configureBlockedReason: String? {
        if !self.supports(Self.configPatchMethod) { return L("This Gateway can't change its configuration remotely.") }
        if self.canConfigure { return nil }
        return L("Changing the Gateway voice needs Full Management access. Ask the Gateway owner to approve it for this device.")
    }

    // MARK: Badges and display names

    public func displayName(for providerId: String) -> String {
        if let name = self.providers.first(where: { $0.id == providerId })?.name, !name.isEmpty { return name }
        if let label = self.status?.providerStates.first(where: { $0.id == providerId })?.label, !label.isEmpty { return label }
        return providerId == "elevenlabs" ? "ElevenLabs" : providerId
    }

    public func isConfigured(_ providerId: String) -> Bool? {
        self.providers.first { $0.id == providerId }?.configured ?? self.status?.providerStates.first { $0.id == providerId }?.configured
    }

    public func badge(for providerId: String) -> TTSProviderBadge {
        if let error = self.lastTestError[providerId] { return .error(error) }
        return self.isConfigured(providerId) == false ? .needsKey : .ready
    }

    /// Known models plus any the Gateway advertises for `providerId`.
    public func modelOptions(for providerId: String) -> [TTSModelOption] {
        let advertised = self.providers.first { $0.id == providerId }?.models ?? []
        return TTSProviderKeys.models(providerId, advertised: advertised)
    }

    func modelName(_ id: String?, provider: String) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return self.modelOptions(for: provider).first { $0.id == id }?.name ?? id
    }

    // MARK: Reading config

    /// Reads `config.get` into `setups`. Best effort: without it the page still works read-only.
    func loadSetups() async {
        guard self.supports(Self.configGetMethod), let result = try? await self.call(Self.configGetMethod) else { return }
        let snapshot = ConfigSnapshot(response: result)
        var node: JSONValue? = snapshot.config
        for key in TTSProviderKeys.configRoot { node = node?[key] }
        var setups: [String: TTSProviderSetup] = [:]
        for (id, value) in node?[TTSProviderKeys.providersKey]?.object ?? [:] {
            setups[id] = Self.parseSetup(value, keys: TTSProviderKeys.forProvider(id))
        }
        self.setups = setups
    }

    static func parseSetup(_ json: JSONValue, keys: TTSProviderKeys) -> TTSProviderSetup {
        var setup = TTSProviderSetup()
        if let keyName = keys.apiKey, let key = json[keyName] {
            if case .object = key, let source = key["source"]?.text, let id = key["id"]?.text {
                setup.keySource = .secretRef(source: source, provider: key["provider"]?.text ?? "", id: id)
            } else if let text = key.text, !text.isEmpty {
                setup.keySource = text.uppercased().contains("REDACTED") ? .redacted : .inline
            }
        }
        if let name = keys.model, let value = json[name]?.text, !value.isEmpty { setup.model = value }
        if let name = keys.voice, let value = json[name]?.text, !value.isEmpty { setup.voice = value }
        if let name = keys.voiceSettings, let value = json[name], case .object = value { setup.voiceSettings = TTSVoiceSettings(json: value) }
        return setup
    }

    // MARK: Writing config

    static func nested(_ path: [String], _ value: JSONValue) -> JSONValue {
        path.reversed().reduce(value) { .object([$1: $0]) }
    }

    private func providerPatch(_ provider: String, _ fields: [String: JSONValue]) -> JSONValue {
        Self.nested(TTSProviderKeys.configRoot + [TTSProviderKeys.providersKey, provider], .object(fields))
    }

    /// `config.patch` with the current hash (retried once when it went stale), then refreshes state.
    func writeConfig(_ patch: JSONValue, note: String) async throws -> ConfigApplyOutcome {
        guard self.canConfigure else { throw ConfigWriteError.adminRequired }
        var lastError = ConfigWriteError.staleHash
        for _ in 0..<2 {
            var params: [String: JSONValue] = ["raw": .string(patch.compactString()), "note": .string(note)]
            if let result = try? await self.call(Self.configGetMethod), let hash = ConfigSnapshot(response: result).hash {
                params["baseHash"] = .string(hash)
            }
            do {
                let result = try await self.call(Self.configPatchMethod, .object(params))
                let outcome = ConfigApplyOutcome(configWrite: result)
                await self.refresh()
                return outcome
            } catch {
                lastError = ConfigWriteError(error)
                if lastError != .staleHash { throw lastError }
            }
        }
        throw lastError
    }

    private func requireKeyField(_ provider: String) throws -> TTSProviderKeys {
        guard self.canConfigure else { throw ConfigWriteError.adminRequired }
        return TTSProviderKeys.forProvider(provider)
    }

    /// Stores `key` on the Gateway (secrets store when it has one, else the config env) and points the
    /// provider's `apiKey` at it. The key is kept in memory for this session only, to list voices.
    public func saveKey(_ key: String, provider: String) async throws -> ConfigApplyOutcome {
        let keys = try self.requireKeyField(provider)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let field = keys.apiKey, let envVar = keys.envVar, !key.isEmpty else {
            throw ConfigWriteError.other(L("That provider doesn't take an API key."))
        }
        var patch: JSONValue
        let ref: JSONValue
        if self.supports(Self.secretsSetMethod) {
            do {
                _ = try await self.call(Self.secretsSetMethod, ["name": .string(envVar), "value": .string(key), "kind": "secret"])
            } catch { throw ConfigWriteError(error) }
            ref = ["source": "store", "provider": .string(TTSProviderKeys.storeSecretProvider), "id": .string(envVar)]
            patch = self.providerPatch(provider, [field: ref])
        } else {
            ref = ["source": "env", "provider": .string(TTSProviderKeys.envSecretProvider), "id": .string(envVar)]
            patch = self.providerPatch(provider, [field: ref])
            let env = Self.nested(TTSProviderKeys.envVarsPath, [envVar: .string(key)])
            patch = Self.merged(patch, env)
        }
        let outcome = try await self.writeConfig(patch, note: "Pincer: Gateway voice key")
        self.sessionKeys[provider] = key
        self.lastTestError[provider] = nil
        return outcome
    }

    public func saveModel(_ id: String, provider: String) async throws -> ConfigApplyOutcome {
        let keys = try self.requireKeyField(provider)
        guard let field = keys.model else { throw ConfigWriteError.other(L("That provider has no model setting.")) }
        let outcome = try await self.writeConfig(self.providerPatch(provider, [field: .string(id)]), note: "Pincer: Gateway voice model")
        self.lastTestError[provider] = nil
        return outcome
    }

    public func saveVoice(_ id: String, provider: String) async throws -> ConfigApplyOutcome {
        let keys = try self.requireKeyField(provider)
        guard let field = keys.voice else { throw ConfigWriteError.other(L("That provider has no voice setting.")) }
        let outcome = try await self.writeConfig(self.providerPatch(provider, [field: .string(id)]), note: "Pincer: Gateway voice")
        self.lastTestError[provider] = nil
        return outcome
    }

    public func saveVoiceSettings(_ settings: TTSVoiceSettings, provider: String) async throws -> ConfigApplyOutcome {
        let keys = try self.requireKeyField(provider)
        guard let field = keys.voiceSettings else { throw ConfigWriteError.other(L("That provider has no voice settings.")) }
        return try await self.writeConfig(self.providerPatch(provider, [field: settings.json]), note: "Pincer: Gateway voice settings")
    }

    /// Deep-merges two nested object patches.
    static func merged(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        guard case let .object(x) = a, case let .object(y) = b else { return b }
        return .object(x.merging(y) { merged($0, $1) })
    }

    // MARK: Voices

    /// The account's ElevenLabs voices. Uses `apiKey`, else the key pasted this session; never persisted.
    public func listElevenLabsVoices(apiKey: String?) async throws -> [ElevenLabsVoice] {
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 } ?? self.sessionKeys["elevenlabs"]
        let voices: [ElevenLabsVoice]
        if let lister = self.voiceLister {
            voices = try await lister(key)
        } else {
            guard let key else { throw TTSSetupError.needsKey }
            voices = try await Self.fetchElevenLabsVoices(apiKey: key)
        }
        if let key { self.sessionKeys["elevenlabs"] = key }
        self.voices = voices
        return voices
    }

    static func fetchElevenLabsVoices(apiKey: String) async throws -> [ElevenLabsVoice] {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw TTSSetupError.invalidKey }
            throw TTSSetupError.failed(String(format: L("ElevenLabs returned HTTP %d."), http.statusCode))
        }
        return try parseElevenLabsVoices(data)
    }

    static func parseElevenLabsVoices(_ data: Data) throws -> [ElevenLabsVoice] {
        let json = try JSONValue.decode(data)
        return (json["voices"]?.array ?? []).compactMap { item in
            guard let id = item["voice_id"]?.text, !id.isEmpty else { return nil }
            return ElevenLabsVoice(id: id, name: item["name"]?.text ?? id, category: item["category"]?.text,
                                   previewURL: item["preview_url"]?.text.flatMap(URL.init(string:)))
        }
    }

    // MARK: Test

    /// Speaks `sample` through the Gateway's configured chain and reports which provider answered.
    public func test(sample: String) async -> TTSTestResult {
        if let blocked = self.testBlocker { return TTSTestResult(outcome: .failed(blocked)) }
        if self.status == nil { await self.refresh() }
        let selected = self.status?.provider ?? ""
        let selectedName = selected.isEmpty ? nil : self.displayName(for: selected)
        let setup = self.setups[selected]
        let model = self.modelName(setup?.model, provider: selected)
        let voiceName = setup?.voice.map { id in self.voices.first { $0.id == id }?.name ?? id }
        let start = ContinuousClock.now
        func elapsed() -> Int {
            let d = ContinuousClock.now - start
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let clip = try await self.speak(sample)
            let ms = elapsed()
            guard let used = clip.provider, !selected.isEmpty, used != selected else {
                self.lastTestError[selected] = nil
                return TTSTestResult(outcome: .success, provider: selectedName ?? clip.provider.map(self.displayName(for:)),
                                     model: model, voiceName: voiceName, durationMs: ms, clip: clip)
            }
            let reason = await self.fallbackReason(selected: selected, setup: setup)
            self.lastTestError[selected] = reason.message
            return TTSTestResult(outcome: .fellBack(to: self.displayName(for: used), reason: reason), provider: self.displayName(for: used),
                                 model: nil, voiceName: nil, durationMs: ms, clip: clip)
        } catch {
            let message = Self.message(error)
            if !selected.isEmpty, !GatewayError.isMissingScope(error) { self.lastTestError[selected] = message }
            return TTSTestResult(outcome: .failed(message), provider: selectedName, model: model, voiceName: voiceName, durationMs: elapsed())
        }
    }

    /// Why `canSpeak` is false.
    var cannotSpeakReason: TTSFallbackReason {
        if !self.supports(Self.speakMethod) { return .gatewayUnsupported }
        if !self.canWrite { return .noWritePermission }
        return .notConfigured(provider: self.displayName(for: self.status?.provider ?? ""))
    }

    /// Synchronous best guess for a read where another provider answered.
    func fallbackReasonForRead(selected: String) -> TTSFallbackReason {
        if self.isConfigured(selected) == false { return .notConfigured(provider: self.displayName(for: selected)) }
        if case .secretRef = self.setups[selected]?.keySource { return .keyNotResolving }
        return .other(L("The selected voice failed, so the Gateway used another provider."))
    }

    private var testBlocker: String? {
        if !self.supports(Self.speakMethod) { return TTSFallbackReason.gatewayUnsupported.message }
        if !self.canWrite { return TTSFallbackReason.noWritePermission.message }
        return nil
    }

    /// Why the Gateway answered with another provider. `tts.convert` with an explicit provider disables
    /// fallback, so its error is the provider's real one.
    private func fallbackReason(selected: String, setup: TTSProviderSetup?) async -> TTSFallbackReason {
        let name = self.displayName(for: selected)
        if self.isConfigured(selected) == false { return .notConfigured(provider: name) }
        if self.supports(Self.convertMethod) {
            var params: [String: JSONValue] = ["text": "Test", "provider": .string(selected)]
            if let model = setup?.model { params["modelId"] = .string(model) }
            if let voice = setup?.voice { params["voiceId"] = .string(voice) }
            do {
                _ = try await self.call(Self.convertMethod, .object(params))
            } catch {
                let message = Self.message(error)
                return setup?.model != nil || setup?.voice != nil ? .modelRejected(message) : .other(message)
            }
        }
        if case .secretRef = setup?.keySource { return .keyNotResolving }
        return .other(L("The selected voice failed, so the Gateway used another provider."))
    }

    // MARK: Effective config

    public var effectiveConfig: [TTSEffectiveRow] {
        guard let status = self.status, !status.provider.isEmpty else { return [] }
        let provider = status.provider
        let setup = self.setups[provider]
        let keys = TTSProviderKeys.forProvider(provider)
        let elevenLabs = provider == "elevenlabs"
        let defaultSpeed = TTSVoiceSettings.elevenLabsDefault
        var rows = [TTSEffectiveRow(label: L("Provider"), value: self.displayName(for: provider), source: L("Gateway config"))]
        if let persona = status.persona, !persona.isEmpty {
            let name = status.personas.first { $0.id == persona }?.displayName ?? persona
            rows.append(TTSEffectiveRow(label: L("Persona"), value: name, source: L("Local /tts prefs")))
        }
        if keys.model != nil {
            let model = setup?.model
            rows.append(TTSEffectiveRow(label: L("Model"), value: self.modelName(model ?? (elevenLabs ? "eleven_multilingual_v2" : nil), provider: provider) ?? L("Provider default"),
                                        source: model == nil ? L("Default") : L("Gateway config")))
        }
        if keys.voice != nil {
            let voice = setup?.voice
            rows.append(TTSEffectiveRow(label: L("Voice"), value: voice.map { id in self.voices.first { $0.id == id }?.name ?? id } ?? L("Provider default"),
                                        source: voice == nil ? L("Default") : L("Gateway config")))
        }
        if keys.voiceSettings != nil {
            let settings = setup?.voiceSettings
            let speed = settings?.speed ?? defaultSpeed.speed
            rows.append(TTSEffectiveRow(label: L("Speed"), value: String(format: "%.2f×", speed), source: settings == nil ? L("Default") : L("Gateway config")))
        }
        rows.append(TTSEffectiveRow(label: L("Auto speak"), value: status.auto, source: L("Local /tts prefs")))
        return rows
    }

    /// What Read Aloud's automatic mode does on this Gateway.
    public var readAloudSummary: ReadAloudGatewaySummary {
        if !self.supports(Self.speakMethod) { return .fallback(.gatewayUnsupported) }
        if !self.canWrite { return .fallback(.noWritePermission) }
        if let status = self.status {
            if !status.hasConfiguredProvider {
                return .fallback(.notConfigured(provider: self.displayName(for: status.provider)))
            }
            if !status.provider.isEmpty, self.isConfigured(status.provider) == false {
                return .fallback(.notConfigured(provider: self.displayName(for: status.provider)))
            }
        }
        let provider = self.status?.provider ?? ""
        return .automatic(provider: provider.isEmpty ? L("Gateway voice") : self.displayName(for: provider),
                          model: self.modelName(self.setups[provider]?.model, provider: provider), gateway: self.gatewayName())
    }
}
