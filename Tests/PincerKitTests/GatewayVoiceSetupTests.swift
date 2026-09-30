import Foundation
import Testing
@testable import PincerKit

/// A Gateway that keeps a config, records every call, and can be told to fail.
@MainActor
private final class FakeGateway {
    var calls: [(method: String, params: JSONValue)] = []
    var errors: [String: GatewayError] = [:]
    var provider = "openai"
    var configured: [String: Bool] = ["openai": true, "elevenlabs": false]
    var tts: [String: JSONValue] = [:]
    var speakProvider = "openai"
    var convertError: GatewayError?
    var storedSecrets: [String] = []
    var configProvider: String?
    var methods: [String] { calls.map(\.method) }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        calls.append((method, params))
        if let error = errors[method] { throw error }
        switch method {
        case "tts.status":
            let states = configured.sorted { $0.key < $1.key }.map { "{\"id\":\"\($0.key)\",\"label\":\"\($0.key == "elevenlabs" ? "ElevenLabs" : "OpenAI")\",\"configured\":\($0.value)}" }
            return Fixtures.json("{\"enabled\":false,\"auto\":\"off\",\"provider\":\"\(provider)\",\"providerStates\":[\(states.joined(separator: ","))]}")
        case "tts.providers":
            return Fixtures.json("{\"providers\":[{\"id\":\"openai\",\"name\":\"OpenAI\",\"configured\":\(configured["openai"] ?? false),\"models\":[\"gpt-4o-mini-tts\"],\"voices\":[\"alloy\"]},{\"id\":\"elevenlabs\",\"name\":\"ElevenLabs\",\"configured\":\(configured["elevenlabs"] ?? false),\"models\":[\"eleven_v3\"],\"voices\":[]}],\"active\":\"\(provider)\"}")
        case "config.get":
            var node: JSONValue = ["providers": .object(tts)]
            if let configProvider, case var .object(o) = node { o["provider"] = .string(configProvider); node = .object(o) }
            for key in TTSProviderKeys.configRoot.reversed() { node = .object([key: node]) }
            guard case let .object(config) = node else { return [:] }
            return ["hash": "h1", "config": .object(config)]
        case "secrets.store.list":
            return ["entries": .array(storedSecrets.map { ["name": .string($0), "kind": "secret"] })]
        case "tts.speak":
            return Fixtures.json("{\"audioBase64\":\"AAEC\",\"provider\":\"\(speakProvider)\",\"mimeType\":\"audio/mpeg\",\"fileExtension\":\"mp3\"}")
        case "tts.convert":
            if let convertError { throw convertError }
            return ["audioPath": "/tmp/x.mp3"]
        default:
            return [:]
        }
    }

    func calls(_ method: String) -> [JSONValue] { calls.filter { $0.method == method }.map(\.params) }

    /// The parsed `raw` of the only `config.patch`.
    func patch() -> JSONValue? {
        guard let raw = calls("config.patch").first?["raw"]?.text else { return nil }
        return Fixtures.json(raw)
    }
}

private let allMethods: Set<String> = ["tts.status", "tts.providers", "tts.personas", "tts.speak", "tts.convert", "tts.setProvider",
                                       "config.get", "config.patch", "secrets.store.set", "secrets.store.list"]

@MainActor
private func makeModel(_ g: FakeGateway, methods: Set<String>? = allMethods, scopes: [String] = ["operator.admin"],
                       demo: Bool = false) -> GatewayVoiceModel
{
    GatewayVoiceModel(methods: { methods }, scopes: { scopes }, allowsWritesWithoutAdmin: demo, gatewayName: { "Studio" },
                      request: { try await g.request($0, $1) })
}

private func rpc(_ code: String, _ message: String) -> GatewayError { .rpc(code: code, message: message, details: nil) }

private func providerNode(_ patch: JSONValue?, _ provider: String) -> JSONValue? {
    var node = patch
    for key in TTSProviderKeys.configRoot + [TTSProviderKeys.providersKey, provider] { node = node?[key] }
    return node
}

@Suite("Gateway voice setup")
@MainActor
struct GatewayVoiceSetupTests {
    // MARK: Permissions

    @Test func adminCanConfigure() {
        let model = makeModel(FakeGateway())
        #expect(model.canConfigure && model.configureBlockedReason == nil)
    }

    @Test func writeScopeAloneCannotConfigure() {
        let model = makeModel(FakeGateway(), scopes: ["operator.read", "operator.write"])
        #expect(!model.canConfigure)
        #expect(model.configureBlockedReason?.contains("Full Management") == true)
    }

    @Test func demoCanConfigureWithoutScopes() {
        #expect(makeModel(FakeGateway(), scopes: [], demo: true).canConfigure)
    }

    @Test func withoutAdminNothingIsSent() async {
        let g = FakeGateway()
        let model = makeModel(g, scopes: ["operator.write"])
        await #expect(throws: ConfigWriteError.adminRequired) { _ = try await model.saveKey("xi-secret", provider: "elevenlabs") }
        await #expect(throws: ConfigWriteError.adminRequired) { _ = try await model.saveModel("eleven_v3", provider: "elevenlabs") }
        await #expect(throws: ConfigWriteError.adminRequired) { _ = try await model.saveVoice("v1", provider: "elevenlabs") }
        await #expect(throws: ConfigWriteError.adminRequired) { _ = try await model.saveVoiceSettings(.elevenLabsDefault, provider: "elevenlabs") }
        #expect(g.calls.isEmpty)
    }

    @Test func unadvertisedConfigPatchBlocks() {
        let model = makeModel(FakeGateway(), methods: ["tts.status", "tts.speak"])
        #expect(model.configureBlockedReason != nil)
    }

    // MARK: Saving the key

    @Test func saveKeyStoresSecretThenPatchesSecretRef() async throws {
        let g = FakeGateway()
        let model = makeModel(g)
        _ = try await model.saveKey("  xi-super-secret \n", provider: "elevenlabs")

        let store = try #require(g.calls("secrets.store.set").first)
        #expect(store == ["name": "ELEVENLABS_API_KEY", "value": "xi-super-secret", "kind": "secret"])
        let order = g.methods.filter { $0 == "secrets.store.set" || $0 == "config.patch" }
        #expect(order == ["secrets.store.set", "config.patch"])

        let ref: JSONValue = ["source": "store", "provider": "default", "id": "ELEVENLABS_API_KEY"]
        #expect(providerNode(g.patch(), "elevenlabs") == ["apiKey": ref])
        let params = try #require(g.calls("config.patch").first)
        #expect(params["baseHash"]?.text == "h1")
        #expect(params["raw"]?.text?.contains("xi-super-secret") == false, "the key never travels in config.patch")
        #expect(params["note"]?.text?.isEmpty == false)
    }

    @Test func saveKeyFallsBackToEnvWhenStoreIsNotAdvertised() async throws {
        let g = FakeGateway()
        let model = makeModel(g, methods: allMethods.subtracting(["secrets.store.set"]))
        _ = try await model.saveKey("xi-super-secret", provider: "elevenlabs")
        #expect(g.calls("secrets.store.set").isEmpty)
        let patch = try #require(g.patch())
        let ref: JSONValue = ["source": "env", "provider": "default", "id": "ELEVENLABS_API_KEY"]
        #expect(providerNode(patch, "elevenlabs") == ["apiKey": ref])
        #expect(patch["env"]?["vars"]?["ELEVENLABS_API_KEY"]?.text == "xi-super-secret")
    }

    @Test func saveKeyFailureDoesNotPatchConfig() async {
        let g = FakeGateway()
        g.errors["secrets.store.set"] = rpc("INVALID_REQUEST", "bad name")
        let model = makeModel(g)
        await #expect(throws: ConfigWriteError.self) { _ = try await model.saveKey("k", provider: "elevenlabs") }
        #expect(g.calls("config.patch").isEmpty)
    }

    @Test func emptyKeyIsRejected() async {
        let g = FakeGateway()
        let model = makeModel(g)
        await #expect(throws: ConfigWriteError.self) { _ = try await model.saveKey("   ", provider: "elevenlabs") }
        #expect(g.calls.isEmpty)
    }

    @Test func providerWithoutKeyRefusesSaveKey() async {
        let g = FakeGateway()
        let model = makeModel(g)
        await #expect(throws: ConfigWriteError.self) { _ = try await model.saveKey("k", provider: "microsoft") }
        #expect(g.calls.isEmpty)
    }

    @Test func staleHashRetriesOnce() async throws {
        let g = FakeGateway()
        var attempts = 0
        let model = GatewayVoiceModel(methods: { allMethods }, scopes: { ["operator.admin"] }, request: { method, params in
            if method == "config.patch" {
                attempts += 1
                if attempts == 1 { throw rpc("INVALID_REQUEST", "config changed since last load; re-run config.get and retry with a fresh base hash") }
            }
            return try await g.request(method, params)
        })
        _ = try await model.saveModel("eleven_v3", provider: "elevenlabs")
        #expect(attempts == 2)
    }

    // MARK: Model, voice, settings

    @Test func saveModelWritesTheProvidersRealKey() async throws {
        let g = FakeGateway()
        _ = try await makeModel(g).saveModel("eleven_v4_turbo", provider: "elevenlabs")
        #expect(providerNode(g.patch(), "elevenlabs") == ["modelId": "eleven_v4_turbo"])

        let o = FakeGateway()
        _ = try await makeModel(o).saveModel("gpt-4o-mini-tts", provider: "openai")
        #expect(providerNode(o.patch(), "openai") == ["model": "gpt-4o-mini-tts"])
    }

    @Test func saveVoiceWritesVoiceId() async throws {
        let g = FakeGateway()
        _ = try await makeModel(g).saveVoice("21m00Tcm4TlvDq8ikWAM", provider: "elevenlabs")
        let node = providerNode(g.patch(), "elevenlabs")
        #expect(node?["speakerVoiceId"]?.text == "21m00Tcm4TlvDq8ikWAM" && node?["voiceId"] == nil, "canonical key wins upstream")
        #expect(g.calls("secrets.store.set").isEmpty)
    }

    @Test func saveVoiceKeepsLegacyVoiceIdInSync() async throws {
        let g = FakeGateway()
        g.tts["elevenlabs"] = ["voiceId": "old"]
        let model = makeModel(g)
        await model.refresh()
        _ = try await model.saveVoice("new", provider: "elevenlabs")
        let node = providerNode(g.patch(), "elevenlabs")
        #expect(node?["speakerVoiceId"]?.text == "new" && node?["voiceId"]?.text == "new")
    }

    @Test func speakerVoiceIdWinsWhenReading() async {
        let g = FakeGateway()
        g.tts["elevenlabs"] = ["voiceId": "old", "speakerVoiceId": "new"]
        let model = makeModel(g)
        await model.refresh()
        #expect(model.setups["elevenlabs"]?.voice == "new")
    }

    @Test func saveVoiceSettingsWritesAllFiveValues() async throws {
        let g = FakeGateway()
        let s = TTSVoiceSettings(stability: 0.3, similarityBoost: 0.9, style: 0.2, useSpeakerBoost: false, speed: 1.25)
        _ = try await makeModel(g).saveVoiceSettings(s, provider: "elevenlabs")
        let node = try #require(providerNode(g.patch(), "elevenlabs")?["voiceSettings"])
        #expect(node["stability"]?.double == 0.3 && node["similarityBoost"]?.double == 0.9 && node["style"]?.double == 0.2
                && node["useSpeakerBoost"]?.bool == false && node["speed"]?.double == 1.25)
    }

    @Test func voiceSettingsRangesForElevenLabs() {
        let d = TTSVoiceSettings.elevenLabsDefault
        for value in [d.stability, d.similarityBoost, d.style] { #expect((0.0 ... 1.0).contains(value)) }
        #expect((0.5 ... 2.0).contains(d.speed))
    }

    @Test func providerWithoutVoiceSettingsRefusesThem() async {
        let g = FakeGateway()
        await #expect(throws: ConfigWriteError.self) { _ = try await makeModel(g).saveVoiceSettings(.elevenLabsDefault, provider: "openai") }
        #expect(g.calls.isEmpty)
    }

    // MARK: Reading the setup back

    @Test func setupsParseSecretRefModelVoiceAndSettings() async {
        let g = FakeGateway()
        g.tts["elevenlabs"] = Fixtures.json(#"""
        {"apiKey":{"source":"store","provider":"default","id":"__OPENCLAW_REDACTED__"},"modelId":"eleven_v4_turbo","voiceId":"abc",
         "voiceSettings":{"stability":0.4,"similarityBoost":0.6,"style":0.1,"useSpeakerBoost":false,"speed":1.1}}
        """#)
        g.tts["openai"] = Fixtures.json(#"{"apiKey":"__OPENCLAW_REDACTED__","model":"gpt-4o-mini-tts","voice":"alloy"}"#)
        let model = makeModel(g)
        await model.refresh()
        let e = model.setups["elevenlabs"]
        #expect(e?.keySource == .secretRef(source: "store", provider: "default", id: nil))
        #expect(e?.model == "eleven_v4_turbo" && e?.voice == "abc")
        #expect(e?.voiceSettings == TTSVoiceSettings(stability: 0.4, similarityBoost: 0.6, style: 0.1, useSpeakerBoost: false, speed: 1.1))
        #expect(model.setups["openai"]?.keySource == .redacted && model.setups["openai"]?.model == "gpt-4o-mini-tts")
    }

    private func redactedStoreRef(_ g: FakeGateway) {
        g.tts["elevenlabs"] = Fixtures.json(#"{"apiKey":{"source":"store","provider":"default","id":"__OPENCLAW_REDACTED__"}}"#)
    }

    @Test func redactedKeyNameIsUnknownByDefault() async {
        let g = FakeGateway()
        redactedStoreRef(g)
        let model = makeModel(g)
        await model.refresh()
        #expect(model.knownKeyName(for: "elevenlabs") == nil)
        #expect(!model.keySourceText(for: "elevenlabs").contains("ELEVENLABS_API_KEY"))
    }

    @Test func redactedKeyNameIsKnownFromSecretsList() async {
        let g = FakeGateway()
        redactedStoreRef(g)
        g.storedSecrets = ["ELEVENLABS_API_KEY"]
        let model = makeModel(g)
        await model.refresh()
        #expect(model.knownKeyName(for: "elevenlabs") == "ELEVENLABS_API_KEY")
        #expect(model.keySourceText(for: "elevenlabs").contains("ELEVENLABS_API_KEY"))
    }

    @Test func listedNameOfAnotherSecretDoesNotCount() async {
        let g = FakeGateway()
        redactedStoreRef(g)
        g.storedSecrets = ["OPENAI_API_KEY"]
        let model = makeModel(g)
        await model.refresh()
        #expect(model.knownKeyName(for: "elevenlabs") == nil)
    }

    @Test func redactedKeyNameIsKnownWhenThisSessionWroteIt() async throws {
        let g = FakeGateway()
        redactedStoreRef(g)
        let model = makeModel(g)
        _ = try await model.saveKey("xi-key", provider: "elevenlabs")
        #expect(model.knownKeyName(for: "elevenlabs") == "ELEVENLABS_API_KEY")
    }

    @Test func unreadableKeyIsAnErrorBadgeNotNeedsKey() async {
        let g = FakeGateway()
        redactedStoreRef(g)
        let model = makeModel(g)
        await model.refresh()
        #expect(model.badge(for: "elevenlabs") == .error("The ElevenLabs key is set, but the Gateway can't read it."))

        let none = FakeGateway()
        let bare = makeModel(none)
        await bare.refresh()
        #expect(bare.badge(for: "elevenlabs") == .needsKey, "needs key only when no key is set")
    }

    @Test func voiceListGatewayErrorBecomesFailedWithoutCode() async {
        let model = makeModel(FakeGateway())
        model.voiceLister = { _ in throw rpc("UNAVAILABLE", "ElevenLabs API error (401): invalid_api_key") }
        do {
            _ = try await model.listElevenLabsVoices(apiKey: "k")
            Issue.record("expected an error")
        } catch let error as TTSSetupError {
            #expect(error == .failed("ElevenLabs API error (401): invalid_api_key"))
            #expect(error.errorDescription?.contains("UNAVAILABLE") == false)
        } catch { Issue.record("expected TTSSetupError, got \(error)") }
    }

    @Test func badgeFollowsConfiguredState() async {
        let g = FakeGateway()
        let model = makeModel(g)
        await model.refresh()
        #expect(model.badge(for: "openai") == .ready)
        #expect(model.badge(for: "elevenlabs") == .needsKey)
    }

    // MARK: Test voice

    private func elevenLabsReady(_ g: FakeGateway) {
        g.provider = "elevenlabs"
        g.configured["elevenlabs"] = true
        g.speakProvider = "elevenlabs"
        g.tts["elevenlabs"] = ["apiKey": ["source": "store", "provider": "default", "id": "X"], "modelId": "eleven_v4_turbo", "voiceId": "rachel-id"]
    }

    @Test func successReportsProviderModelVoiceAndTime() async {
        let g = FakeGateway()
        elevenLabsReady(g)
        let model = makeModel(g)
        model.voiceLister = { _ in [ElevenLabsVoice(id: "rachel-id", name: "Rachel")] }
        await model.refresh()
        _ = try? await model.listElevenLabsVoices(apiKey: "k")
        let result = await model.test(sample: "Hello")
        #expect(result.outcome == .success && result.clip != nil)
        #expect(result.provider == "ElevenLabs" && result.model == "Eleven v4 Turbo" && result.voiceName == "Rachel")
        let parts = result.summary.components(separatedBy: " · ")
        #expect(parts.count == 4 && Array(parts.prefix(3)) == ["ElevenLabs", "Eleven v4 Turbo", "Rachel"] && parts[3].hasSuffix(" ms"))
        #expect(g.calls("tts.speak").first?["text"]?.text == "Hello")
        #expect(model.badge(for: "elevenlabs") == .ready)
    }

    @Test func summaryFormat() {
        let r = TTSTestResult(outcome: .success, provider: "ElevenLabs", model: "Eleven v4 Turbo", voiceName: "Rachel", durationMs: 820)
        #expect(r.summary == "ElevenLabs · Eleven v4 Turbo · Rachel · 820 ms")
        #expect(TTSTestResult(outcome: .failed("nope")).summary == "nope")
    }

    @Test func providerErrorIsShownNotHidden() async {
        let g = FakeGateway()
        elevenLabsReady(g)
        g.errors["tts.speak"] = rpc("UNAVAILABLE", "ElevenLabs API error (401): invalid_api_key")
        let model = makeModel(g)
        await model.refresh()
        let result = await model.test(sample: "Hello")
        #expect(result.outcome == .failed("ElevenLabs API error (401): invalid_api_key") && result.clip == nil)
        #expect(model.badge(for: "elevenlabs") == .error("ElevenLabs API error (401): invalid_api_key"))
    }

    @Test func fallbackIsDetectedWhenAnotherProviderSpoke() async {
        let g = FakeGateway()
        elevenLabsReady(g)
        g.speakProvider = "openai"
        g.convertError = rpc("UNAVAILABLE", "model eleven_v4_turbo not found")
        let model = makeModel(g)
        await model.refresh()
        let result = await model.test(sample: "Hello")
        guard case let .fellBack(to, reason) = result.outcome else { Issue.record("expected fellBack, got \(result.outcome)"); return }
        #expect(to == "OpenAI")
        #expect(reason == .modelRejected("model eleven_v4_turbo not found"))
        #expect(g.calls("tts.convert").first?["provider"]?.text == "elevenlabs", "explicit provider disables upstream fallback")
        #expect(model.badge(for: "elevenlabs") != .ready)
    }

    @Test func unconfiguredSelectedProviderFallbackSaysNotConfigured() async {
        let g = FakeGateway()
        g.provider = "elevenlabs"
        g.speakProvider = "openai"
        let model = makeModel(g)
        await model.refresh()
        let result = await model.test(sample: "Hello")
        #expect(result.outcome == .fellBack(to: "OpenAI", reason: .notConfigured(provider: "ElevenLabs")))
    }

    @Test func testNeedsWritePermission() async {
        let g = FakeGateway()
        let result = await makeModel(g, scopes: ["operator.read"]).test(sample: "Hi")
        guard case .failed = result.outcome else { Issue.record("expected failure"); return }
        #expect(g.calls("tts.speak").isEmpty)
    }

    // MARK: Read Aloud summary

    @Test func readAloudSummaryAutomatic() async {
        let g = FakeGateway()
        elevenLabsReady(g)
        let model = makeModel(g)
        await model.refresh()
        #expect(model.readAloudSummary == .automatic(provider: "ElevenLabs", model: "Eleven v4 Turbo", gateway: "Studio"))
    }

    @Test func readAloudSummaryFallbacks() async {
        let g = FakeGateway()
        g.provider = "elevenlabs"
        let unconfigured = makeModel(g)
        await unconfigured.refresh()
        guard case let .gatewayFallback(selected, _, using) = unconfigured.readAloudSummary else { Issue.record("expected gatewayFallback"); return }
        #expect(selected == "ElevenLabs" && using == "OpenAI")
        #expect(makeModel(g, scopes: ["operator.read"]).readAloudSummary == .fallback(.noWritePermission))
        #expect(makeModel(g, methods: ["tts.status"]).readAloudSummary == .fallback(.gatewayUnsupported))
    }

    @Test func effectiveConfigRows() async {
        let g = FakeGateway()
        elevenLabsReady(g)
        g.tts["elevenlabs"] = Fixtures.json(#"{"modelId":"eleven_v4_turbo","voiceSettings":{"speed":1.5}}"#)
        let model = makeModel(g)
        await model.refresh()
        let rows = Dictionary(uniqueKeysWithValues: model.effectiveConfig.map { ($0.label, $0) })
        #expect(rows["Provider"]?.value == "ElevenLabs")
        #expect(rows["Model"]?.value == "Eleven v4 Turbo" && rows["Model"]?.source == "Gateway config")
        #expect(rows["Voice"]?.source == "Default")
        #expect(rows["Speed"]?.value == "1.5×")
    }

    @Test func summaryAlwaysIncludesAVoice() {
        #expect(TTSTestResult(outcome: .success, provider: "ElevenLabs", model: "Eleven v4 Turbo", voiceName: nil, durationMs: 5).summary
                == "ElevenLabs · Eleven v4 Turbo · Default voice · 5 ms")
    }

    @Test func voiceNameFallsBackToId() async {
        let g = FakeGateway()
        elevenLabsReady(g)
        let model = makeModel(g)
        await model.refresh()
        let result = await model.test(sample: "Hi")
        #expect(result.summary.contains("rachel-id"))
    }

    @Test func keySetButUnreadableIsKeyNotResolving() async {
        let g = FakeGateway()
        g.provider = "elevenlabs"
        g.configured["elevenlabs"] = false
        g.tts["elevenlabs"] = Fixtures.json(#"{"apiKey":{"source":"store","provider":"default","id":"__OPENCLAW_REDACTED__"}}"#)
        let model = makeModel(g)
        await model.refresh()
        let problem = model.providerProblem(for: "elevenlabs")
        #expect(problem?.cause == .key)
        #expect(problem?.message == "The ElevenLabs key is set, but the Gateway can't read it.")
        #expect(TTSFallbackReason.keyNotResolving.message(provider: "ElevenLabs") == "The ElevenLabs key is set, but the Gateway can't read it.")
    }

    @Test func problemCauseIsClassified() async {
        let g = FakeGateway()
        elevenLabsReady(g)
        g.errors["tts.speak"] = rpc("UNAVAILABLE", "ElevenLabs API error (400): model_id_does_not_exist")
        let model = makeModel(g)
        await model.refresh()
        _ = await model.test(sample: "Hi")
        #expect(model.providerProblem(for: "elevenlabs")?.cause == .model)
    }

    @Test func effectiveProviderSourceFollowsConfig() async {
        let g = FakeGateway()
        g.provider = "openai"
        g.configProvider = "openai"
        let same = makeModel(g)
        await same.refresh()
        #expect(same.effectiveConfig.first { $0.label == "Provider" }?.source == "Gateway config")

        g.configProvider = "elevenlabs"
        let differs = makeModel(g)
        await differs.refresh()
        #expect(differs.effectiveConfig.first { $0.label == "Provider" }?.source == "Local /tts preferences")
    }

    @Test func fallbackReasonMessagesAreNonEmpty() {
        let reasons: [TTSFallbackReason] = [.noWritePermission, .notConfigured(provider: "ElevenLabs"), .keyNotResolving, .modelRejected("x"),
                                            .gatewayUnsupported, .deviceOnlySetting, .other("boom")]
        for reason in reasons { #expect(!reason.message.isEmpty) }
        #expect(TTSFallbackReason.notConfigured(provider: "ElevenLabs").message.contains("ElevenLabs"))
        #expect(TTSFallbackReason.other("boom").message == "boom")
    }

    // MARK: Voices

    @Test func voiceListingNeedsAKeyAndRemembersItInMemory() async throws {
        let model = makeModel(FakeGateway())
        model.voiceLister = { key in
            guard key != nil else { throw TTSSetupError.needsKey }
            return [ElevenLabsVoice(id: "1", name: "Rachel")]
        }
        await #expect(throws: TTSSetupError.needsKey) { _ = try await model.listElevenLabsVoices(apiKey: nil) }
        #expect(try await model.listElevenLabsVoices(apiKey: "k").map(\.name) == ["Rachel"])
        #expect(try await model.listElevenLabsVoices(apiKey: nil).count == 1, "the pasted key is reused this session")
    }

    @Test func parsesElevenLabsVoicesResponse() throws {
        let data = Data(#"{"voices":[{"voice_id":"a","name":"Rachel","category":"premade","preview_url":"https://x.test/a.mp3"},{"name":"no id"}]}"#.utf8)
        let voices = try GatewayVoiceModel.parseElevenLabsVoices(data)
        #expect(voices == [ElevenLabsVoice(id: "a", name: "Rachel", category: "premade", previewURL: URL(string: "https://x.test/a.mp3"))])
    }
}
