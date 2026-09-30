import Foundation
import Observation

/// Gateway text-to-speech for one Gateway: `tts.status/providers/personas` for the Voice settings
/// page, and `tts.speak` for Read Aloud. Pincer never plays `tts.convert` output (it returns a path on
/// the Gateway host, which a remote client can't read); it only uses it to explain a fallback.
/// Setup (key, model, voice) lives in `GatewayVoiceModel+Setup.swift`.
@MainActor @Observable
public final class GatewayVoiceModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public static let statusMethod = "tts.status"
    public static let providersMethod = "tts.providers"
    public static let personasMethod = "tts.personas"
    public static let enableMethod = "tts.enable"
    public static let disableMethod = "tts.disable"
    public static let setProviderMethod = "tts.setProvider"
    public static let setPersonaMethod = "tts.setPersona"
    public static let speakMethod = "tts.speak"
    public static let writeScope = "operator.write"

    public private(set) var status: TTSStatus?
    public private(set) var providers: [TTSProvider] = []
    public private(set) var personas: [TTSPersona] = []
    public private(set) var activePersona: String?
    public private(set) var loadError: String?
    public private(set) var isLoading = false
    /// Methods the Gateway answered with unknown-method.
    public private(set) var rejectedMethods: Set<String> = []

    /// Per-provider setup read from `config.get` (key source, model, voice, voice settings).
    public internal(set) var setups: [String: TTSProviderSetup] = [:]
    /// `tts.provider` from config (nil when unset); differs from `status.provider` when prefs or a persona override it.
    public internal(set) var configuredProvider: String?
    /// Names in the Gateway secrets store (admin only).
    /// Whether `tts.setProvider` succeeded this session (the provider then comes from local prefs).
    public internal(set) var providerSetThisSession = false
    public internal(set) var secretNames: Set<String> = []
    /// The last Test voice failure or fallback per provider id, for the provider badge.
    public internal(set) var lastTestError: [String: String] = [:]
    /// ElevenLabs voices from the last successful listing (names for the Test summary).
    public internal(set) var voices: [ElevenLabsVoice] = []
    /// Demo/test hook: replaces the ElevenLabs voices request. Receives the session key (nil when none was pasted).
    @ObservationIgnored public var voiceLister: (@MainActor (_ apiKey: String?) async throws -> [ElevenLabsVoice])?

    @ObservationIgnored let request: Request
    @ObservationIgnored let methods: @MainActor () -> Set<String>?
    @ObservationIgnored let scopes: @MainActor () -> [String]
    @ObservationIgnored let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored let gatewayName: @MainActor () -> String
    /// API keys pasted this session; memory only, never persisted or logged.
    @ObservationIgnored var sessionKeys: [String: String] = [:]
    /// Providers whose key this session saved, so the secret's name is known even though config.get redacts it.
    public internal(set) var wroteKey: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var statusAttempted = false

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, allowsWritesWithoutAdmin: Bool,
         gatewayName: @escaping @MainActor () -> String = { "" })
    {
        self.gatewayName = gatewayName
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    /// For checks and tests. `methods` is the advertised list (nil or empty when unknown).
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [GatewayConnection.adminScope] },
                allowsWritesWithoutAdmin: Bool = false,
                gatewayName: @escaping @MainActor () -> String = { "" },
                request: @escaping Request)
    {
        self.gatewayName = gatewayName
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    /// Whether the Gateway has `method`: advertised (or the list is unknown) and not rejected.
    public func supports(_ method: String) -> Bool {
        if self.rejectedMethods.contains(method) { return false }
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    /// Whether the Voice settings page applies.
    public var supportsStatus: Bool { self.supports(Self.statusMethod) }

    /// `operator.write` (or admin), or the demo.
    public var canWrite: Bool {
        if self.allowsWritesWithoutAdmin { return true }
        let scopes = self.scopes()
        return scopes.contains(Self.writeScope) || scopes.contains(GatewayConnection.adminScope)
    }

    /// Whether Read Aloud's automatic mode should use the Gateway voice: `tts.speak` is available, this
    /// connection may write, and (once status has loaded) some provider is configured.
    public var canSpeak: Bool {
        guard self.supports(Self.speakMethod), self.canWrite else { return false }
        guard let status = self.status else { return true }
        return status.providerStates.isEmpty || status.providerStates.contains { $0.configured }
    }

    /// Loads `tts.status` once per connection (no-op when it's cached, unsupported, or already failed), so
    /// `canSpeak` knows whether a provider is configured without the Voice page being opened.
    public func loadStatusIfNeeded() async {
        guard self.status == nil, !self.statusAttempted, self.supports(Self.statusMethod), self.supports(Self.speakMethod),
              self.canWrite else { return }
        self.statusAttempted = true
        let generation = self.generation
        guard let result = try? await self.call(Self.statusMethod), generation == self.generation,
              let status = TTSStatus(result), self.status == nil else { return }
        self.status = status
        self.activePersona = status.persona
    }

    public func refresh() async {
        self.generation += 1
        let generation = self.generation
        self.isLoading = true
        self.loadError = nil
        defer { if generation == self.generation { self.isLoading = false } }
        var firstError: String?
        if self.supports(Self.statusMethod) {
            do {
                let result = try await self.call(Self.statusMethod)
                guard generation == self.generation else { return }
                if let status = TTSStatus(result) {
                    self.status = status
                    self.activePersona = status.persona
                    if self.personas.isEmpty { self.personas = status.personas }
                }
            } catch { firstError = firstError ?? Self.message(error) }
        }
        if self.supports(Self.providersMethod) {
            do {
                let result = try await self.call(Self.providersMethod)
                guard generation == self.generation else { return }
                self.providers = result["providers"]?.array?.compactMap(TTSProvider.init) ?? []
            } catch { firstError = firstError ?? Self.message(error) }
        }
        if self.supports(Self.personasMethod) {
            do {
                let result = try await self.call(Self.personasMethod)
                guard generation == self.generation else { return }
                self.personas = result["personas"]?.array?.compactMap(TTSPersona.init) ?? []
                if let active = result["active"]?.text, !active.isEmpty { self.activePersona = active }
            } catch { firstError = firstError ?? Self.message(error) }
        }
        guard generation == self.generation else { return }
        await self.loadSetups()
        guard generation == self.generation else { return }
        self.loadError = firstError
    }

    public var autoMode: TTSAutoMode? { self.status?.autoMode }

    /// True when turning auto-speak Off/Always would replace inbound/tagged, which Pincer can't set back.
    public func setAutoSpeakNeedsConfirmation(_ on: Bool) -> Bool {
        _ = on
        return self.autoMode?.isNotSettable ?? false
    }

    /// `tts.enable` / `tts.disable`: whether the Gateway attaches spoken audio to every channel reply.
    public func setAutoSpeakChannels(_ on: Bool) async throws {
        let result = try await self.call(on ? Self.enableMethod : Self.disableMethod)
        let enabled = result["enabled"]?.bool ?? on
        if var status = self.status {
            status.enabled = enabled
            status.auto = enabled ? "always" : "off"
            self.status = status
        }
    }

    public func setProvider(_ id: String) async throws {
        let configured = self.providers.first { $0.id == id }?.configured ?? self.status?.providerStates.first { $0.id == id }?.configured
        if configured == false {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: L("That provider isn't configured on the Gateway."), details: nil)
        }
        let result = try await self.call(Self.setProviderMethod, ["provider": .string(id)])
        let provider = result["provider"]?.text ?? id
        self.providerSetThisSession = true
        if var status = self.status {
            status.provider = provider
            self.status = status
        }
    }

    /// `nil` clears the persona (the Gateway takes "off").
    public func setPersona(_ id: String?) async throws {
        let result = try await self.call(Self.setPersonaMethod, ["persona": .string(id ?? "off")])
        let persona = result["persona"]?.text
        self.activePersona = persona?.isEmpty == false ? persona : nil
        if var status = self.status {
            status.persona = self.activePersona
            self.status = status
        }
    }

    /// `tts.speak`. Text longer than the Gateway allows is the caller's to truncate.
    public func speak(_ text: String) async throws -> TTSClip {
        let result = try await self.call(Self.speakMethod, ["text": .string(text)])
        guard let clip = TTSClip(result) else {
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "The Gateway returned no audio.", details: nil)
        }
        return clip
    }

    public func handleReconnect() {
        self.generation += 1
        self.statusAttempted = false
        self.status = nil
        self.providers = []
        self.personas = []
        self.activePersona = nil
        self.loadError = nil
        self.isLoading = false
        self.rejectedMethods = []
        self.setups = [:]
        self.configuredProvider = nil
        self.secretNames = []
        self.providerSetThisSession = false
        self.lastTestError = [:]
    }

    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        do {
            return try await self.request(method, params)
        } catch {
            if GatewayError.isUnknownMethod(error) { self.rejectedMethods.insert(method) }
            throw error
        }
    }

    public static func message(_ error: Error) -> String {
        if GatewayError.isMissingScope(error) { return L("This device needs write access to change voice settings.") }
        if GatewayError.isUnknownMethod(error) { return L("This Gateway doesn't support voice.") }
        if case let GatewayError.rpc(_, message, _) = error { return message }
        return error.localizedDescription
    }
}
