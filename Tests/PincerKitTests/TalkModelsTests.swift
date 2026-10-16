import Foundation
import Testing
@testable import PincerKit

/// Upstream-shaped `talk.catalog` result (openclaw `TalkCatalogResultSchema`).
let talkCatalogFixture: JSONValue = [
    "modes": ["realtime", "stt-tts", "transcription"],
    "transports": ["gateway-relay", "webrtc"],
    "brains": ["agent-consult", "direct-tools", "none"],
    "speech": ["ready": true, "activeProvider": "elevenlabs", "providers": [["id": "elevenlabs", "label": "ElevenLabs", "configured": true]]],
    "transcription": ["providers": []],
    "realtime": [
        "ready": true, "activeProvider": "gpt",
        "providers": [
            ["id": "google", "label": "Google Live", "configured": false],
            [
                "id": "openai", "label": "OpenAI Realtime", "configured": true, "aliases": ["gpt"],
                "models": ["gpt-realtime"], "voices": ["alloy", "marin"], "defaultModel": "gpt-realtime",
                "modes": ["realtime"], "transports": ["gateway-relay", "webrtc"], "brains": ["agent-consult"],
                "inputAudioFormats": [["encoding": "pcm16", "sampleRateHz": 24000, "channels": 1]],
                "outputAudioFormats": [["encoding": "g711_ulaw", "sampleRateHz": 8000, "channels": 1], ["encoding": "bad"]],
                "supportsBargeIn": true, "supportsToolCalls": true, "futureField": 1,
            ],
        ],
    ],
    "config": [:],
]

func talkCatalog(_ transform: (inout [String: JSONValue]) -> Void = { _ in }) -> TalkCatalog? {
    var object = talkCatalogFixture.object ?? [:]
    transform(&object)
    return TalkCatalog(.object(object))
}

func talkCatalogWith(provider: [String: JSONValue], ready: Bool? = true, active: String? = "p",
                     transports: [String] = ["gateway-relay"], brains: [String] = ["agent-consult"],
                     hint: Bool? = nil) -> TalkCatalog? {
    var realtime: [String: JSONValue] = ["providers": [.object(provider)]]
    if let ready { realtime["ready"] = .bool(ready) }
    if let active { realtime["activeProvider"] = .string(active) }
    var object: [String: JSONValue] = [
        "transports": .array(transports.map { .string($0) }), "brains": .array(brains.map { .string($0) }),
        "modes": ["realtime"], "realtime": .object(realtime),
    ]
    if let hint { object["config"] = ["clientHints": ["realtime": ["gatewayRelaySupported": .bool(hint)]]] }
    return TalkCatalog(.object(object))
}

struct TalkCatalogTests {
    @Test func parsesFullUpstreamShape() throws {
        let catalog = try #require(talkCatalog())
        #expect(catalog.modes == ["realtime", "stt-tts", "transcription"])
        #expect(catalog.transports == ["gateway-relay", "webrtc"])
        #expect(catalog.brains == ["agent-consult", "direct-tools", "none"])
        #expect(catalog.realtimeReady == true && catalog.activeRealtimeProvider == "gpt")
        #expect(catalog.gatewayRelaySupportedHint == nil)
        #expect(catalog.realtimeProviders.map(\.id) == ["google", "openai"])
        let openai = try #require(catalog.realtimeProviders.last)
        #expect(openai.label == "OpenAI Realtime" && openai.configured && openai.aliases == ["gpt"])
        #expect(openai.models == ["gpt-realtime"] && openai.voices == ["alloy", "marin"] && openai.defaultModel == "gpt-realtime")
        #expect(openai.transports == ["gateway-relay", "webrtc"] && openai.brains == ["agent-consult"])
        #expect(openai.inputAudioFormats == [TalkAudioFormat(["encoding": "pcm16", "sampleRateHz": 24000, "channels": 1])!])
        #expect(openai.outputAudioFormats.count == 1 && openai.outputAudioFormats[0].encoding == "g711_ulaw")
        #expect(openai.supportsBargeIn == true && openai.supportsToolCalls == true)
    }

    @Test func parsesMinimalAndMalformed() throws {
        let empty = try #require(TalkCatalog([:]))
        #expect(empty.modes.isEmpty && empty.realtimeProviders.isEmpty && empty.realtimeReady == nil)
        #expect(empty.relayProvider == nil && !empty.supportsRelayCall)
        #expect(TalkCatalog("nope") == nil && TalkCatalog(nil) == nil)
        #expect(TalkProviderParse.provider(["label": "No id"]) == nil)
        let bare = try #require(TalkRealtimeProvider(["id": "x"]))
        #expect(bare.label == "x" && !bare.configured && bare.transports == nil && bare.brains == nil)
        #expect(bare.supportsBargeIn == nil && bare.aliases.isEmpty && bare.inputAudioFormats.isEmpty)
        let junk = try #require(talkCatalog { $0["realtime"] = ["providers": [1, "x", ["id": "ok"]]] })
        #expect(junk.realtimeProviders.map(\.id) == ["ok"])
        #expect(TalkAudioFormat(["encoding": "pcm16"]) == nil)
    }

    @Test func relayProviderResolution() throws {
        let catalog = try #require(talkCatalog())
        #expect(catalog.relayProvider?.id == "openai", "active name is an alias")
        let byId = try #require(talkCatalog { $0["realtime"] = ["activeProvider": "google", "providers": talkCatalogFixture["realtime"]?["providers"] ?? []] })
        #expect(byId.relayProvider?.id == "google", "the active provider wins even if unconfigured")
        let fallback = try #require(talkCatalog { $0["realtime"] = ["providers": talkCatalogFixture["realtime"]?["providers"] ?? []] })
        #expect(fallback.relayProvider?.id == "openai", "no active: first configured")
        let unknownActive = try #require(talkCatalog { $0["realtime"] = ["activeProvider": "zzz", "providers": talkCatalogFixture["realtime"]?["providers"] ?? []] })
        #expect(unknownActive.relayProvider?.id == "openai", "unresolvable active falls back to first configured")
    }

    @Test func supportsRelayCallTruthTable() throws {
        #expect(try #require(talkCatalog()).supportsRelayCall)
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true])?.supportsRelayCall == true)
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true], ready: false)?.supportsRelayCall == false, "ready false")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true], ready: nil)?.supportsRelayCall == true, "ready unknown is fine")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": false])?.supportsRelayCall == false, "unconfigured")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true], transports: ["webrtc"])?.supportsRelayCall == false, "no relay transport")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true, "transports": ["webrtc"]])?.supportsRelayCall == false,
                "provider transports override the catalog")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true, "transports": ["gateway-relay"]], transports: ["webrtc"])?.supportsRelayCall == true,
                "provider transports override the catalog (positive)")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true], transports: ["webrtc"], hint: true)?.supportsRelayCall == true, "hint")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true], transports: ["webrtc"], hint: false)?.supportsRelayCall == false, "hint false")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true], brains: ["none"])?.supportsRelayCall == false, "no agent-consult")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true, "brains": ["agent-consult"]], brains: [])?.supportsRelayCall == true,
                "provider brains override the catalog")
        #expect(talkCatalogWith(provider: ["id": "p", "configured": true, "brains": []])?.supportsRelayCall == false, "empty provider brains")
    }

    @Test func bargeInRule() throws {
        let catalog = try #require(talkCatalog())
        #expect(catalog.supportsBargeIn(provider: "openai") && catalog.supportsBargeIn(provider: "gpt"))
        #expect(catalog.supportsBargeIn(provider: "google"), "unspecified means on")
        #expect(!catalog.supportsBargeIn(provider: "unknown"), "unknown provider is off")
        let off = try #require(talkCatalogWith(provider: ["id": "p", "supportsBargeIn": false]))
        #expect(!off.supportsBargeIn(provider: "p"))
    }
}

private enum TalkProviderParse {
    static func provider(_ json: JSONValue) -> TalkRealtimeProvider? { TalkRealtimeProvider(json) }
}

/// An in-memory stand-in for the per-profile cache.
final class TalkMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private(set) var saves: [String?] = []
    init(_ value: String? = nil) { self.value = value }
    var current: String? { self.lock.withLock { self.value } }
    var persistence: GatewayTalkModel.Persistence {
        .init(load: { self.lock.withLock { self.value } }, save: { new in self.lock.withLock { self.value = new; self.saves.append(new) } })
    }
}

@MainActor
struct GatewayTalkModelTests {
    static let both: Set<String> = [TalkProtocol.catalogMethod, TalkProtocol.sessionCreateMethod]

    @Test func unadvertisedIsUnsupportedAndMakesNoRequest() async {
        var calls = 0
        let model = GatewayTalkModel(methods: { ["chat.send", TalkProtocol.catalogMethod] }, request: { _, _ in calls += 1; return [:] })
        #expect(!model.isAdvertised)
        model.loadCatalogIfNeeded()
        #expect(model.availability == .unsupported)
        await Task.yield()
        #expect(calls == 0)
        let unknownHello = GatewayTalkModel(methods: { nil }, request: { _, _ in [:] })
        #expect(!unknownHello.isAdvertised && unknownHello.availability == .unknown)
    }

    @Test func successBecomesAvailableAndPersists() async {
        let store = TalkMemoryStore()
        var methods: [String] = []
        var params: [JSONValue] = []
        let model = GatewayTalkModel(methods: { Self.both }, persistence: store.persistence, request: { method, p in
            methods.append(method); params.append(p); return talkCatalogFixture
        })
        #expect(model.availability == .unknown)
        model.loadCatalogIfNeeded()
        #expect(await eventually { model.availability == .available(provider: "openai") })
        #expect(methods == [TalkProtocol.catalogMethod] && params == [[:]])
        #expect(model.catalog?.relayProvider?.id == "openai")
        #expect(store.current == "openai")
        model.loadCatalogIfNeeded()
        await Task.yield()
        #expect(methods.count == 1, "once per connection")
    }

    @Test func unconfiguredCatalogIsNotConfiguredAndClearsCache() async {
        let store = TalkMemoryStore("openai")
        let unconfigured = talkCatalog { $0["realtime"] = ["ready": false, "providers": [["id": "openai", "label": "OpenAI", "configured": false]]] }
        let result = JSONValue.object(["modes": ["realtime"], "transports": ["gateway-relay"], "brains": ["agent-consult"],
                                       "realtime": ["ready": false, "providers": [["id": "openai", "configured": false]]]])
        #expect(unconfigured?.supportsRelayCall == false)
        let model = GatewayTalkModel(methods: { Self.both }, persistence: store.persistence, request: { _, _ in result })
        #expect(model.availability == .available(provider: "openai"), "cached positive at init")
        model.loadCatalogIfNeeded()
        #expect(await eventually { model.availability == .notConfigured(nil) })
        #expect(store.current == nil, "the latest answer wins")
    }

    @Test func errorCarriesTheGatewayMessage() async {
        let store = TalkMemoryStore()
        let model = GatewayTalkModel(methods: { Self.both }, persistence: store.persistence, request: { _, _ in
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Talk realtime is not configured", details: nil)
        })
        model.loadCatalogIfNeeded()
        #expect(await eventually { model.availability == .notConfigured("Talk realtime is not configured") })
        #expect(store.current == nil)
    }

    @Test func cachedPositiveUntilFirstAnswerAfterReconnect() async {
        let store = TalkMemoryStore("openai")
        var fail = false
        let model = GatewayTalkModel(methods: { Self.both }, persistence: store.persistence, request: { _, _ in
            if fail { throw GatewayError.rpc(code: "UNAVAILABLE", message: "down", details: nil) }
            return talkCatalogFixture
        })
        #expect(model.availability == .available(provider: "openai"))
        model.loadCatalogIfNeeded()
        #expect(await eventually { model.catalog != nil })
        fail = true
        model.handleReconnect()
        #expect(model.catalog == nil && model.availability == .available(provider: "openai"), "cached value until the new answer")
        model.loadCatalogIfNeeded()
        #expect(await eventually { model.availability == .notConfigured("down") })
    }

    @Test func staleGenerationResultIsIgnored() async {
        let store = TalkMemoryStore()
        var advertised = true
        var answers = 0
        let model = GatewayTalkModel(methods: { advertised ? Self.both : [] }, persistence: store.persistence, request: { _, _ in
            answers += 1
            try await Task.sleep(for: .milliseconds(100))
            return talkCatalogFixture
        })
        model.loadCatalogIfNeeded()
        advertised = false
        model.reset()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(answers == 1 && model.catalog == nil && model.availability == .unsupported, "the first connection's answer is dropped")
        #expect(!store.saves.contains("openai"))
    }

    @Test func cachedAvailableWithUnadvertisedGatewayBecomesUnsupportedAndClearsCache() async {
        let store = TalkMemoryStore("openai")
        var calls = 0
        let model = GatewayTalkModel(methods: { ["chat.send"] }, persistence: store.persistence, request: { _, _ in calls += 1; return talkCatalogFixture })
        #expect(model.availability == .available(provider: "openai"), "cached positive at init")
        model.handleReconnect()
        #expect(model.availability == .unsupported && store.current == nil, "reconnect to a Gateway without Talk")
        await Task.yield()
        #expect(calls == 0)
        let again = TalkMemoryStore("openai")
        let viaRefresh = GatewayTalkModel(methods: { [TalkProtocol.catalogMethod] }, persistence: again.persistence, request: { _, _ in [:] })
        viaRefresh.loadCatalogIfNeeded()
        #expect(viaRefresh.availability == .unsupported && again.current == nil, "only one of the two Talk methods is not advertised")
    }

    @Test func transportErrorKeepsAvailabilityAndCacheAndRetries() async {
        let store = TalkMemoryStore("openai")
        var attempts = 0
        var fail = true
        let model = GatewayTalkModel(methods: { Self.both }, persistence: store.persistence, request: { _, _ in
            attempts += 1
            if fail { throw GatewayError.notConnected }
            return talkCatalogFixture
        })
        model.loadCatalogIfNeeded()
        #expect(await eventually { attempts == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.availability == .available(provider: "openai") && store.current == "openai" && store.saves.isEmpty,
                "a dropped request doesn't change what was known")
        model.loadCatalogIfNeeded()
        #expect(await eventually { attempts == 2 }, "the next load retries")
        fail = false
        model.loadCatalogIfNeeded()
        #expect(await eventually { model.catalog != nil && attempts == 3 })
        #expect(model.availability == .available(provider: "openai"))

        let fresh = GatewayTalkModel(methods: { Self.both }, request: { _, _ in throw URLError(.timedOut) })
        fresh.loadCatalogIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fresh.availability == .unknown, "no answer yet: still unknown, not notConfigured")
    }

    @Test func unknownMethodAnswerIsUnsupported() async {
        for error in [GatewayError.rpc(code: "UNKNOWN_METHOD", message: "x", details: nil),
                      GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method: talk.catalog", details: nil)] {
            let store = TalkMemoryStore("openai")
            let model = GatewayTalkModel(methods: { Self.both }, persistence: store.persistence, request: { _, _ in throw error })
            model.loadCatalogIfNeeded()
            #expect(await eventually { model.availability == .unsupported })
            #expect(store.current == nil && model.catalog == nil)
        }
    }

    @Test func persistenceUsesInjectedDefaultsAndDemoDoesNotPersist() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let persistence = GatewayTalkModel.Persistence.defaults(scratch.defaults, gatewayId: "gw-1")
        #expect(persistence.load() == nil)
        persistence.save("openai")
        #expect(GatewayTalkModel.Persistence.defaults(scratch.defaults, gatewayId: "gw-1").load() == "openai")
        #expect(GatewayTalkModel.Persistence.defaults(scratch.defaults, gatewayId: "gw-2").load() == nil)
        persistence.save(nil)
        #expect(persistence.load() == nil)
        GatewayTalkModel.Persistence.none.save("x")
        #expect(GatewayTalkModel.Persistence.none.load() == nil)
    }

    @Test func demoStoreNeverWritesTalkDefaults() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let demo = GatewayStore(profile: GatewayProfile(name: "Demo", url: DemoGateway.url, authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        demo.talk.apply(catalog: talkCatalog())
        #expect(demo.talk.availability == .available(provider: "openai"))
        #expect(scratch.defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("pincer.talk.") })
    }
}
