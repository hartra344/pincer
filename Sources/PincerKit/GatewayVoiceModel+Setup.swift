import Foundation

// Gateway Voice setup (#459): provider badges, API key / model / voice / voice settings written through
// `config.patch` (and `secrets.store.set`), a Test voice call, and the effective-config summary.

public enum VoiceKeyRemovalPolicy {
    /// Whether removing this provider's key changes the provider currently used for replies.
    public static func shouldExplainFallback(activeProvider: String?, removingProvider: String) -> Bool {
        activeProvider != nil && activeProvider == removingProvider
    }
}

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
        /// `id` is nil when the Gateway redacted it.
        case secretRef(source: String, provider: String, id: String?)
        /// Present, but the Gateway hid it.
        case redacted
    }

    public var keySource: KeySource
    public var model: String?
    public var voice: String?
    public var voiceSettings: TTSVoiceSettings?
    /// A `model` value the provider doesn't read (ElevenLabs reads `modelId`); it is silently ignored.
    public var ignoredModel: String?
    /// The legacy voice key (e.g. `voiceId`) is also present in config, so writes must update it too.
    public var hasLegacyVoiceKey: Bool

    public init(keySource: KeySource = .none, model: String? = nil, voice: String? = nil, voiceSettings: TTSVoiceSettings? = nil,
                ignoredModel: String? = nil, hasLegacyVoiceKey: Bool = false)
    {
        self.ignoredModel = ignoredModel
        self.hasLegacyVoiceKey = hasLegacyVoiceKey
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
        case .noWritePermission: L("This device can't use the Gateway voice (no write access), so it used this device's voice.")
        case let .notConfigured(provider): String(format: L("%@ isn't set up on the Gateway yet."), provider)
        case .keyNotResolving: L("The key is set, but the Gateway can't read it.")
        case let .modelRejected(detail): String(format: L("The provider rejected the model or voice: %@"), detail)
        case .gatewayUnsupported: L("This Gateway can't speak replies. Update it to use a Gateway voice.")
        case .deviceOnlySetting: L("Read Aloud is set to This Device Only.")
        case let .other(detail): detail
        }
    }

    /// The message naming `provider` where the case doesn't carry it.
    public func message(provider: String) -> String {
        switch self {
        case .keyNotResolving: String(format: L("The %@ key is set, but the Gateway can't read it."), provider)
        case let .modelRejected(detail): String(format: L("%@ rejected the model or voice: %@"), provider, detail)
        default: self.message
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
            let voice = self.voiceName.flatMap { $0.isEmpty ? nil : $0 } ?? (self.outcome == .success ? L("Default voice") : nil)
            let parts = [self.provider, self.model, voice].compactMap { $0 }.filter { !$0.isEmpty }
            return (parts + ["\(self.durationMs) ms"]).joined(separator: " · ")
        }
    }
}

public struct TTSEffectiveRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    /// "Gateway config", "Local /tts prefs", "Persona <x>" or "Default".
    public let source: String
    /// Raw config path for power users, e.g. "providers.elevenlabs.modelId"; nil when it has none.
    public let keyPath: String?
    /// Set when a local override (prefs, persona) wins over what the setup sections show.
    public let overrideNote: String?
    public var id: String { self.label }

    public init(label: String, value: String, source: String, keyPath: String? = nil, overrideNote: String? = nil) {
        self.label = label
        self.value = value
        self.source = source
        self.keyPath = keyPath
        self.overrideNote = overrideNote
    }
}

public enum ReadAloudGatewaySummary: Equatable, Sendable {
    case automatic(provider: String, model: String?, gateway: String)
    case fallback(TTSFallbackReason)
    /// The active provider can't be used but the Gateway still speaks, with `using` (a display name, if known).
    case gatewayFallback(selected: String, reason: TTSFallbackReason, using: String?)
}

/// What is wrong with a provider, so a header can be reason-neutral and advise per cause.
public struct TTSProviderProblem: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        case key, model, voice
        case other(String)
    }

    public let cause: Cause
    public let message: String

    public init(cause: Cause, message: String) {
        self.cause = cause
        self.message = message
    }

    /// Best guess from a provider error text.
    static func classify(_ message: String) -> Cause {
        let m = message.lowercased()
        if m.contains("model") { return .model }
        if m.contains("voice") { return .voice }
        if ["401", "unauthorized", "api key", "api-key", "apikey", "invalid key", "invalid_api_key", "key isn't", "key is", "credential", "authenticat"].contains(where: m.contains) { return .key }
        return .other(message)
    }
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
    public static let secretsDeleteMethod = "secrets.store.delete"
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
        if self.isConfigured(providerId) == false {
            if self.keyIsNotResolving(providerId) {
                return .error(TTSFallbackReason.keyNotResolving.message(provider: self.displayName(for: providerId)))
            }
            return .needsKey
        }
        return .ready
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
        func section(_ path: [String]) -> JSONValue? {
            var node: JSONValue? = snapshot.config
            for key in path { node = node?[key] }
            if case .object = node { return node }
            return nil
        }
        let node = section(TTSProviderKeys.configRoot) ?? section(TTSProviderKeys.legacyConfigRoot)
        self.configuredProvider = node?["provider"]?.text
        var setups: [String: TTSProviderSetup] = [:]
        for (id, value) in node?[TTSProviderKeys.providersKey]?.object ?? [:] {
            setups[id] = Self.parseSetup(value, keys: TTSProviderKeys.forProvider(id))
        }
        self.setups = setups
        await self.loadSecretNames()
    }

    /// Names in the secrets store (admin only); confirms the id `config.get` redacts.
    private func loadSecretNames() async {
        guard self.canConfigure, self.supports("secrets.store.list"),
              let result = try? await self.call("secrets.store.list") else { return }
        self.secretNames = Set((result["entries"]?.array ?? []).compactMap { $0["name"]?.text ?? $0.text })
    }

    static func parseSetup(_ json: JSONValue, keys: TTSProviderKeys) -> TTSProviderSetup {
        var setup = TTSProviderSetup()
        if let keyName = keys.apiKey, let key = json[keyName] {
            if case .object = key, let source = key["source"]?.text, let id = key["id"]?.text {
                let shown = id.uppercased().contains("REDACTED") ? nil : id
                setup.keySource = .secretRef(source: source, provider: key["provider"]?.text ?? "", id: shown)
            } else if let text = key.text, !text.isEmpty {
                setup.keySource = text.uppercased().contains("REDACTED") ? .redacted : .inline
            }
        }
        if let name = keys.model {
            if let value = json[name]?.text, !value.isEmpty {
                setup.model = value
            } else if name == "modelId", let value = json["model"]?.text, !value.isEmpty {
                setup.ignoredModel = value
            }
        }
        // The speaker* name wins at runtime when both are present.
        for name in [keys.voiceAlias, keys.voice].compactMap({ $0 }) {
            if let value = json[name]?.text, !value.isEmpty { setup.voice = value; break }
        }
        if let legacy = keys.voice, keys.voiceAlias != nil, json[legacy] != nil { setup.hasLegacyVoiceKey = true }
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
        self.wroteKey.insert(provider)
        self.lastTestError[provider] = nil
        return outcome
    }

    /// Whether a key can be removed: the provider takes one, one is set, and this connection may write config.
    public func canRemoveKey(_ provider: String) -> Bool {
        guard self.canConfigure, self.supports(Self.configPatchMethod),
              TTSProviderKeys.forProvider(provider).apiKey != nil else { return false }
        switch self.setups[provider]?.keySource ?? .none {
        case .none: return false
        case .secretRef, .inline, .redacted: return true
        }
    }

    /// Clears the provider's `apiKey` (merge-patch `null`). A store ref also deletes the secret afterwards; an env ref
    /// also nulls its `env.vars` entry in the same patch. The key can't be recovered, so callers confirm first.
    public func removeKey(provider: String) async throws -> ConfigApplyOutcome {
        let keys = try self.requireKeyField(provider)
        guard let field = keys.apiKey else { throw ConfigWriteError.other(L("That provider doesn't take an API key.")) }
        var patch = self.providerPatch(provider, [field: .null])
        var secretName: String?
        if case let .secretRef(source, _, id) = self.setups[provider]?.keySource {
            let name = id ?? self.knownKeyName(for: provider) ?? keys.envVar
            if source == "env", let name {
                patch = Self.merged(patch, Self.nested(TTSProviderKeys.envVarsPath, [name: .null]))
            } else if source == "store" { secretName = name }
        }
        let outcome = try await self.writeConfig(patch, note: "Pincer: remove Gateway voice key")
        if let secretName, self.supports(Self.secretsDeleteMethod) {
            do { _ = try await self.call(Self.secretsDeleteMethod, ["name": .string(secretName)]) } catch {
                if !Self.isNotFound(error) { throw ConfigWriteError(error) }
            }
            self.secretNames.remove(secretName)
        }
        self.sessionKeys[provider] = nil
        self.wroteKey.remove(provider)
        self.lastTestError[provider] = nil
        await self.refresh()
        return outcome
    }

    private static func isNotFound(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error else { return false }
        return code == "NOT_FOUND" || message.lowercased().contains("not found")
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
        // speaker* wins at runtime, so write it; keep a legacy key in sync only when the config already has one.
        var fields: [String: JSONValue] = [(keys.voiceAlias ?? field): .string(id)]
        if keys.voiceAlias == nil || self.setups[provider]?.hasLegacyVoiceKey == true { fields[field] = .string(id) }
        let outcome = try await self.writeConfig(self.providerPatch(provider, fields), note: "Pincer: Gateway voice")
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
        do {
            if let lister = self.voiceLister {
                voices = try await lister(key)
            } else {
                guard let key else { throw TTSSetupError.needsKey }
                voices = try await Self.fetchElevenLabsVoices(apiKey: key)
            }
        } catch let error as TTSSetupError {
            throw error
        } catch let error where error is GatewayError {
            throw TTSSetupError.failed(Self.message(error))
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
        let voiceName = self.voiceDisplay(setup?.voice, provider: selected)
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
            self.lastTestError[selected] = reason.message(provider: self.displayName(for: selected))
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
        if self.isConfigured(selected) == false { return self.unusableReason(selected) }
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
        if self.isConfigured(selected) == false { return self.unusableReason(selected) }
        if self.supports(Self.convertMethod) {
            var params: [String: JSONValue] = ["text": "Test", "provider": .string(selected)]
            if let model = setup?.model { params["modelId"] = .string(model) }
            if let voice = setup?.voice { params["voiceId"] = .string(voice) }
            do {
                _ = try await self.call(Self.convertMethod, .object(params))
            } catch {
                let message = Self.message(error)
                switch TTSProviderProblem.classify(message) {
                case .key: return .other(String(format: L("%@ rejected the key: %@"), name, message))
                case .model, .voice: return .modelRejected(message)
                case .other: return .other(message)
                }
            }
        }
        return .other(L("The selected voice failed, so the Gateway used another provider."))
    }

    /// Not configured because no key is set, or the key is set but the Gateway can't read it.
    func unusableReason(_ provider: String) -> TTSFallbackReason {
        let keys = TTSProviderKeys.forProvider(provider)
        switch self.setups[provider]?.keySource ?? .none {
        case .none: return .notConfigured(provider: self.displayName(for: provider))
        default: return keys.apiKey == nil ? .notConfigured(provider: self.displayName(for: provider)) : .keyNotResolving
        }
    }

    /// Why a provider isn't working, from the last test or check, or an unreadable key.
    public func providerProblem(for provider: String) -> TTSProviderProblem? {
        if self.keyIsNotResolving(provider) {
            return TTSProviderProblem(cause: .key, message: TTSFallbackReason.keyNotResolving.message(provider: self.displayName(for: provider)))
        }
        guard let message = self.lastTestError[provider] else { return nil }
        return TTSProviderProblem(cause: TTSProviderProblem.classify(message), message: message)
    }

    // MARK: Effective config

    public var effectiveConfig: [TTSEffectiveRow] {
        guard let status = self.status, !status.provider.isEmpty else { return [] }
        let provider = status.provider
        let setup = self.setups[provider]
        let keys = TTSProviderKeys.forProvider(provider)
        let base = (TTSProviderKeys.configRoot + [TTSProviderKeys.providersKey, provider]).joined(separator: ".")
        let gatewayConfig = L("Gateway config")
        let prefs = L("Local /tts preferences")
        // tts.status doesn't say where the provider came from: a different one in config means prefs or a persona won.
        var providerSource = L("Default")
        var override: String?
        let personaProvider = status.persona.flatMap { id in status.personas.first { $0.id == id }?.provider }
        if let configured = self.configuredProvider {
            providerSource = gatewayConfig
            if configured != provider {
                providerSource = personaProvider == provider ? String(format: L("Persona \"%@\""), status.persona ?? "") : prefs
                override = L("Overridden by local /tts prefs or persona")
            }
        } else if self.providerSetThisSession {
            providerSource = prefs
        }
        var rows = [TTSEffectiveRow(label: L("Provider"), value: self.displayName(for: provider), source: providerSource,
                                    keyPath: (TTSProviderKeys.configRoot + ["provider"]).joined(separator: "."), overrideNote: override)]
        if let persona = status.persona, !persona.isEmpty {
            let name = status.personas.first { $0.id == persona }?.displayName ?? persona
            rows.append(TTSEffectiveRow(label: L("Persona"), value: name, source: String(format: L("Persona \"%@\""), name)))
        }
        if let field = keys.model {
            let model = setup?.model
            rows.append(TTSEffectiveRow(label: L("Model"), value: self.modelDisplay(model, provider: provider), source: model == nil ? L("Default") : gatewayConfig,
                                        keyPath: "\(base).\(field)",
                                        overrideNote: setup?.ignoredModel.map { String(format: L("The config sets model \"%@\", which %@ ignores. Choose a model above to set %@."), $0, self.displayName(for: provider), field) }))
        }
        if let field = keys.voice {
            let voice = setup?.voice
            rows.append(TTSEffectiveRow(label: L("Voice"), value: self.voiceDisplay(voice, provider: provider), source: voice == nil ? L("Default") : gatewayConfig,
                                        keyPath: "\(base).\(keys.voiceAlias ?? field)"))
        }
        if let field = keys.voiceSettings {
            let settings = setup?.voiceSettings
            let d = settings ?? TTSVoiceSettings.elevenLabsDefault
            let source = settings == nil ? L("Default") : gatewayConfig
            let path = "\(base).\(field)"
            rows.append(TTSEffectiveRow(label: L("Speed"), value: String(format: "%.1f×", d.speed), source: source, keyPath: path + ".speed"))
            rows.append(TTSEffectiveRow(label: L("Stability"), value: "\(Int((d.stability * 100).rounded()))%", source: source, keyPath: path + ".stability"))
        }
        if keys.apiKey != nil {
            rows.append(TTSEffectiveRow(label: L("API Key"), value: self.keySourceText(for: provider), source: gatewayConfig,
                                        keyPath: "\(base).apiKey"))
        }
        let autoText = status.auto == "off" || !status.enabled
            ? L("Off. Replies aren't spoken on channels automatically. Read Aloud and Test Voice still work.")
            : Self.autoModeText(status)
        rows.append(TTSEffectiveRow(label: L("Auto-Speak on Channels"), value: autoText, source: prefs))
        return rows
    }

    // MARK: Display text (never blank)

    static func autoModeText(_ status: TTSStatus) -> String {
        status.autoMode?.displayName ?? String(format: L("Unknown (%@)"), status.auto)
    }

    /// The model name to show: the selected one, else the provider's actual default with "(Default)".
    public func modelDisplay(_ id: String?, provider: String) -> String {
        if let id, !id.isEmpty { return self.modelOptions(for: provider).first { $0.id == id }?.name ?? String(format: L("Custom: %@"), id) }
        if let def = TTSProviderKeys.defaultModel(provider), let name = self.modelName(def, provider: provider) { return String(format: L("%@ (Default)"), name) }
        return L("Provider default")
    }

    /// The voice name to show: its name if known, "Default voice", else the raw id.
    public func voiceDisplay(_ id: String?, provider: String) -> String {
        guard let id, !id.isEmpty else { return L("Default voice") }
        if let name = self.voices.first(where: { $0.id == id })?.name { return name }
        if id == TTSProviderKeys.defaultVoice(provider) { return L("Default voice") }
        return id
    }

    /// The ref's name when it isn't redacted, was written by this session, or is listed in the secrets store.
    public func knownKeyName(for provider: String) -> String? {
        guard case let .secretRef(source, _, id) = self.setups[provider]?.keySource else { return nil }
        if let id { return id }
        guard let env = TTSProviderKeys.forProvider(provider).envVar else { return nil }
        if self.wroteKey.contains(provider) || (source == "store" && self.secretNames.contains(env)) { return env }
        return nil
    }

    /// How the API key is provided, for the key section's source line.
    public func keySourceText(for provider: String) -> String {
        let keys = TTSProviderKeys.forProvider(provider)
        guard keys.apiKey != nil else { return L("No key needed") }
        switch self.setups[provider]?.keySource ?? .none {
        case let .secretRef(source, _, _):
            let name = self.knownKeyName(for: provider)
            let broken = self.isConfigured(provider) == false
            switch (source, name) {
            case let ("store", name?):
                return String(format: broken ? L("Set in the Gateway's secrets as %@, but the Gateway can't read it") : L("Stored in the Gateway's secrets as %@"), name)
            case ("store", nil):
                return broken ? L("Set in the Gateway's secrets, but the Gateway can't read it") : L("Stored in the Gateway's secrets")
            case let ("env", name?):
                return String(format: broken ? L("Set to the environment variable %@, but the Gateway can't read it") : L("Stored as the Gateway environment variable %@"), name)
            case ("env", nil):
                return broken ? L("Set to an environment variable, but the Gateway can't read it") : L("From an environment variable on the Gateway")
            default: return L("Set to a secret reference")
            }
        case .inline, .redacted:
            return L("Set in the Gateway's config file")
        case .none:
            return self.isConfigured(provider) == true ? L("From the Gateway's environment or an auth profile") : L("Not set")
        }
    }

    /// True when a key is set but the Gateway can't use it (the original bug: a SecretRef that doesn't resolve).
    public func keyIsNotResolving(_ provider: String) -> Bool {
        if case .secretRef = self.setups[provider]?.keySource { return self.isConfigured(provider) == false }
        return false
    }

    // MARK: Check (no fallback)

    public enum CheckResult: Equatable, Sendable {
        case working
        /// The provider refused (bad key, model or voice): its message.
        case rejected(String)
        /// Couldn't check (no permission, or the Gateway has no `tts.convert`).
        case unavailable
    }

    /// Asks the provider itself, bypassing fallback (`tts.convert` with an explicit provider), so a working
    /// fallback can't mask a bad key, model or voice. Updates the provider's badge.
    public func checkProvider(_ provider: String) async -> CheckResult {
        guard self.supports(Self.convertMethod), self.canWrite else { return .unavailable }
        let setup = self.setups[provider]
        var params: [String: JSONValue] = ["text": "Test", "provider": .string(provider)]
        if let model = setup?.model { params["modelId"] = .string(model) }
        if let voice = setup?.voice { params["voiceId"] = .string(voice) }
        do {
            _ = try await self.call(Self.convertMethod, .object(params))
            self.lastTestError[provider] = nil
            return .working
        } catch {
            if GatewayError.isUnknownMethod(error) || GatewayError.isMissingScope(error) { return .unavailable }
            let message = Self.message(error)
            self.lastTestError[provider] = message
            return .rejected(message)
        }
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
                let candidates = status.fallbackProviders + status.providerStates.map(\.id)
                let using = candidates.first { $0 != status.provider && self.isConfigured($0) == true }
                return .gatewayFallback(selected: self.displayName(for: status.provider), reason: self.unusableReason(status.provider),
                                        using: using.map(self.displayName(for:)))
            }
        }
        let provider = self.status?.provider ?? ""
        return .automatic(provider: provider.isEmpty ? L("Gateway voice") : self.displayName(for: provider),
                          model: self.modelName(self.setups[provider]?.model, provider: provider), gateway: self.gatewayName())
    }
}
