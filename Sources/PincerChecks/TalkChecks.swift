import Foundation
@testable import PincerKit

// Talk (#973 PR 1): talk.catalog parsing, availability, and the `display: false` filter.

private let talkCheckCatalog = json("""
{"modes":["realtime","stt-tts","transcription"],"transports":["gateway-relay","webrtc"],"brains":["agent-consult","direct-tools","none"],
 "speech":{"ready":true,"activeProvider":"openai","providers":[{"id":"openai","label":"OpenAI","configured":true}]},
 "transcription":{"providers":[]},
 "realtime":{"ready":true,"activeProvider":"gpt","providers":[
   {"id":"google","label":"Google Live","configured":false},
   {"id":"openai","label":"OpenAI Realtime","configured":true,"aliases":["gpt"],"defaultModel":"gpt-realtime","voices":["alloy","marin"],
    "transports":["gateway-relay","webrtc"],"brains":["agent-consult"],
    "inputAudioFormats":[{"encoding":"pcm16","sampleRateHz":24000,"channels":1}],"supportsBargeIn":true,"supportsToolCalls":true}]},
 "config":{}}
""")

private let hiddenRecord = json("""
{"role":"user","content":[{"type":"text","text":"consult prompt"}],"display":false,"provenance":{"kind":"internal_system"},"__openclaw":{"id":"hidden-1"}}
""")

@MainActor
func checkTalkOffline() async {
    print("Talk catalog, availability and hidden records")
    let catalog = TalkCatalog(talkCheckCatalog)
    check(catalog?.realtimeProviders.map(\.id) == ["google", "openai"], "catalog parses both realtime providers")
    check(catalog?.relayProvider?.id == "openai", "the active alias resolves to openai")
    check(catalog?.supportsRelayCall == true, "relay call supported")
    check(catalog?.supportsBargeIn(provider: "gpt") == true && catalog?.supportsBargeIn(provider: "nope") == false, "barge-in rule")
    check(TalkCatalog(json("[]")) == nil && TalkCatalog([:])?.supportsRelayCall == false, "malformed and empty catalogs")

    var requests: [String] = []
    nonisolated(unsafe) var cached: String?
    let persistence = GatewayTalkModel.Persistence(load: { cached }, save: { cached = $0 })
    let model = GatewayTalkModel(methods: { [TalkProtocol.catalogMethod, TalkProtocol.sessionCreateMethod] }, persistence: persistence,
                                 request: { method, _ in requests.append(method); return talkCheckCatalog })
    check(model.availability == .unknown, "availability starts unknown")
    model.loadCatalogIfNeeded()
    let ok38 = await waitFor("talk availability", timeout: 5) { model.availability == .available(provider: "openai") }
    check(ok38, "catalog load → available(openai)")
    check(cached == "openai" && requests == [TalkProtocol.catalogMethod], "positive answer cached; one request")

    let unsupported = GatewayTalkModel(methods: { ["chat.send"] }, request: { _, _ in [:] })
    unsupported.loadCatalogIfNeeded()
    check(unsupported.availability == .unsupported, "unadvertised Gateway → unsupported")

    let failing = GatewayTalkModel(methods: { [TalkProtocol.catalogMethod, TalkProtocol.sessionCreateMethod] }, request: { _, _ in
        throw GatewayError.rpc(code: "UNAVAILABLE", message: "realtime not configured", details: nil)
    })
    failing.loadCatalogIfNeeded()
    let ok50 = await waitFor("talk error", timeout: 5) { failing.availability == .notConfigured("realtime not configured") }
    check(ok50, "error → notConfigured(message)")

    nonisolated(unsafe) var staleCache: String? = "openai"
    let staleStore = GatewayTalkModel.Persistence(load: { staleCache }, save: { staleCache = $0 })
    let dropped = GatewayTalkModel(methods: { ["chat.send"] }, persistence: staleStore, request: { _, _ in [:] })
    check(dropped.availability == .available(provider: "openai"), "cached available at init")
    dropped.handleReconnect()
    check(dropped.availability == .unsupported && staleCache == nil, "cached available + Talk not advertised → unsupported, cache emptied")

    nonisolated(unsafe) var attempts = 0
    nonisolated(unsafe) var keptCache: String? = "openai"
    let keptStore = GatewayTalkModel.Persistence(load: { keptCache }, save: { keptCache = $0 })
    let flaky = GatewayTalkModel(methods: { [TalkProtocol.catalogMethod, TalkProtocol.sessionCreateMethod] }, persistence: keptStore, request: { _, _ in
        attempts += 1
        throw GatewayError.notConnected
    })
    flaky.loadCatalogIfNeeded()
    let tried = await waitFor("first attempt", timeout: 5) { attempts == 1 }
    check(tried && flaky.availability == .available(provider: "openai") && keptCache == "openai", "transport error keeps availability and cache")
    flaky.loadCatalogIfNeeded()
    let retried = await waitFor("retry", timeout: 5) { attempts == 2 }
    check(retried, "the next load retries after a transport error")

    let unknown = GatewayTalkModel(methods: { [TalkProtocol.catalogMethod, TalkProtocol.sessionCreateMethod] }, request: { _, _ in
        throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)
    })
    unknown.loadCatalogIfNeeded()
    let unknownAnswered = await waitFor("unknown method", timeout: 5) { unknown.availability == .unsupported }
    check(unknownAnswered, "advertised but unknown method → unsupported")

    let afterHidden = ChatStore.parse([json(#"{"role":"user","content":"q","__openclaw":{"id":"u1"}}"#), hiddenRecord,
                                       json(#"{"role":"assistant","content":"A","__openclaw":{"id":"a1"}}"#)])
    check(afterHidden.last?.followsHiddenPrompt == true && afterHidden.first?.followsHiddenPrompt != true, "history flags the reply that follows a hidden prompt")
    check(ChatStore.parse([hiddenRecord]).isEmpty, "a page of only hidden records parses to nothing (paging must use the raw count)")

    check(ChatStore.parse([hiddenRecord, json(#"{"role":"assistant","content":"Hi","__openclaw":{"id":"v1"}}"#)]).map(\.id) == ["v1"],
          "history parsing skips display:false")
    let gateway = GatewayStore(profile: GatewayProfile(name: "Offline talk", url: "ws://127.0.0.1:9", authMode: .none))
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    let chat = ChatStore(sessionKey: "agent:main:main", agentId: "main", gateway: gateway)
    chat.handleSessionMessage(["message": hiddenRecord])
    check(chat.items.isEmpty && chat.reloadTask == nil && !chat.stale, "hidden session.message: no item, no reload scheduled")
    chat.handleSessionMessage(["message": json(#"{"role":"assistant","content":"Hi","__openclaw":{"id":"v1"}}"#)])
    let ok62 = await waitFor("visible message appended", timeout: 5) { chat.items.map(\.id) == ["v1"] }
    check(ok62, "visible session.message still appends")
}

@MainActor
func runLiveTalkChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock talk", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("mock for talk", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "mock for talk connected")
    guard connected else { gateway.stop(); return }
    defer { gateway.stop() }
    check(gateway.talk.isAdvertised, "hello advertises talk.catalog and talk.session.create")
    let available = await waitFor("talk available", timeout: 15) { gateway.talk.availability == .available(provider: "openai") }
    check(available, "GatewayTalkModel reaches available(openai) (got \(gateway.talk.availability))")
    check(gateway.talk.catalog?.supportsBargeIn(provider: "openai") == true, "mock provider supports barge-in")

    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let before = chat.items.count
    await chat.send(HiddenConsult.trigger)
    let ok86 = await waitFor("hidden consult run to finish", timeout: 20) { !chat.isRunning && chat.items.count > before }
    check(ok86, "hidden-consult run finished")
    let ok88 = await waitFor("visible reply", timeout: 10) { chat.items.last?.role == .assistant }
    check(ok88, "the visible assistant reply is shown")
    check(!chat.items.contains { $0.plainText.contains(HiddenConsult.marker) }, "the display:false consult prompt never appears live")
    let liveReply = chat.items.last { $0.role == .assistant }
    check(liveReply?.followsHiddenPrompt == true && liveReply.map { !chat.canRegenerate($0.id) } == true,
          "live: the reply after the hidden prompt is flagged and can't be regenerated")
    let history = try? await gateway.connection.request("chat.history", ["sessionKey": "agent:main:main", "limit": 50], timeout: 20)
    let raw = history?["messages"]?.array ?? []
    check(raw.contains { $0.isHiddenFromChat }, "the Gateway history does contain the hidden record (the filter is not vacuous)")
    await chat.load(force: true)
    check(!chat.items.contains { $0.plainText.contains(HiddenConsult.marker) }, "…and a history reload still hides it")
    check(chat.items.contains { $0.plainText == HiddenConsult.trigger }, "the typed trigger itself stays visible")
    // The reply that answers the hidden prompt is shown but is not the answer to anything visible.
    let reply = chat.items.last { $0.role == .assistant }
    check(reply?.followsHiddenPrompt == true, "the reply after the hidden prompt is flagged (history)")
    check(reply.map { !chat.canRegenerate($0.id) } == true, "…and it can't be regenerated")
}

private enum HiddenConsult {
    static let trigger = "/mock hidden-consult"
    static let marker = "[talk consult]"
}
