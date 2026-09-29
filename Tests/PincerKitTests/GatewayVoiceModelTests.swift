import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class Recorder {
    var calls: [(method: String, params: JSONValue)] = []
    var replies: [String: JSONValue] = [:]
    var errors: [String: GatewayError] = [:]
    var methods: [String] { calls.map(\.method) }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        calls.append((method, params))
        if let error = errors[method] { throw error }
        return replies[method] ?? [:]
    }
}

private let allMethods: Set<String> = ["tts.status", "tts.providers", "tts.personas", "tts.enable", "tts.disable",
                                       "tts.setProvider", "tts.setPersona", "tts.convert", "tts.speak"]
private let statusJSON = #"""
{"enabled":false,"auto":"off","provider":"openai","persona":null,"personas":[{"id":"narrator"}],
 "providerStates":[{"id":"openai","label":"OpenAI","configured":true}]}
"""#

@MainActor
private func makeModel(_ recorder: Recorder, methods: Set<String>? = allMethods,
                       scopes: [String] = ["operator.read", "operator.write"], demo: Bool = false) -> GatewayVoiceModel
{
    GatewayVoiceModel(methods: { methods }, scopes: { scopes }, allowsWritesWithoutAdmin: demo, request: { try await recorder.request($0, $1) })
}

private func rpc(_ code: String, _ message: String) -> GatewayError { .rpc(code: code, message: message, details: nil) }

@Suite("Gateway voice model")
@MainActor
struct GatewayVoiceModelTests {
    @Test func supportsFollowsAdvertisedList() {
        let r = Recorder()
        #expect(makeModel(r).supports("tts.speak"))
        #expect(!makeModel(r, methods: ["tts.status"]).supports("tts.speak"))
        #expect(makeModel(r, methods: nil).supports("tts.speak"), "unknown list assumes yes")
        #expect(makeModel(r, methods: []).supports("tts.speak"), "empty list is unknown")
    }

    @Test func canWriteByScope() {
        let r = Recorder()
        #expect(makeModel(r, scopes: ["operator.write"]).canWrite)
        #expect(makeModel(r, scopes: ["operator.admin"]).canWrite)
        #expect(!makeModel(r, scopes: ["operator.read"]).canWrite)
        #expect(makeModel(r, scopes: [], demo: true).canWrite)
    }

    @Test func canSpeakRules() async {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        let model = makeModel(r)
        #expect(model.canSpeak, "status not loaded yet")
        await model.refresh()
        #expect(model.canSpeak)

        #expect(!makeModel(r, methods: ["tts.status"]).canSpeak, "tts.speak not advertised")
        #expect(!makeModel(r, scopes: ["operator.read"]).canSpeak, "no write scope")
        #expect(makeModel(r, scopes: [], demo: true).canSpeak, "demo needs no scope")

        let none = Recorder()
        none.replies["tts.status"] = Fixtures.json(#"{"enabled":false,"provider":"x","providerStates":[{"id":"x","label":"X","configured":false}]}"#)
        let unconfigured = makeModel(none)
        await unconfigured.refresh()
        #expect(!unconfigured.canSpeak, "no provider configured")
        unconfigured.handleReconnect()
        #expect(unconfigured.canSpeak, "reset status is unknown again")
    }

    @Test func rejectedMethodsStopSpeaking() async {
        let r = Recorder()
        r.errors["tts.speak"] = rpc("UNKNOWN_METHOD", "unknown method: tts.speak")
        let model = makeModel(r)
        await #expect(throws: GatewayError.self) { try await model.speak("hi") }
        #expect(model.rejectedMethods.contains("tts.speak") && !model.supports("tts.speak") && !model.canSpeak)
        model.handleReconnect()
        #expect(model.supports("tts.speak"))
    }

    @Test func otherErrorsAreNotRemembered() async {
        let r = Recorder()
        r.errors["tts.speak"] = rpc("UNAVAILABLE", "TTS synthesis failed")
        let model = makeModel(r)
        await #expect(throws: GatewayError.self) { try await model.speak("hi") }
        #expect(model.supports("tts.speak"))
    }

    @Test func speakSendsOnlyTextAndParsesClip() async throws {
        let r = Recorder()
        r.replies["tts.speak"] = Fixtures.json(#"{"audioBase64":"AAEC","provider":"openai","mimeType":"audio/wav","fileExtension":"wav"}"#)
        let clip = try await makeModel(r).speak("Hello")
        #expect(r.calls.count == 1 && r.calls[0].method == "tts.speak" && r.calls[0].params == ["text": "Hello"])
        #expect(clip.data == Data([0, 1, 2]) && clip.provider == "openai")
    }

    @Test func speakWithoutAudioThrows() async {
        let r = Recorder()
        r.replies["tts.speak"] = Fixtures.json(#"{"provider":"openai"}"#)
        await #expect(throws: GatewayError.self) { try await makeModel(r).speak("Hello") }
    }

    @Test func refreshLoadsAllThree() async {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        r.replies["tts.providers"] = Fixtures.json(#"{"providers":[{"id":"openai","name":"OpenAI","configured":true,"models":[],"voices":["alloy"]}],"active":"openai"}"#)
        r.replies["tts.personas"] = Fixtures.json(#"{"active":"narrator","personas":[{"id":"narrator","label":"Narrator","providers":["openai"]}]}"#)
        let model = makeModel(r)
        await model.refresh()
        #expect(r.methods == ["tts.status", "tts.providers", "tts.personas"])
        #expect(model.status?.provider == "openai" && model.providers.map(\.id) == ["openai"])
        #expect(model.personas.map(\.id) == ["narrator"] && model.activePersona == "narrator")
        #expect(model.loadError == nil && !model.isLoading)
    }

    @Test func refreshSkipsUnsupportedMethods() async {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        let model = makeModel(r, methods: ["tts.status"])
        await model.refresh()
        #expect(r.methods == ["tts.status"])
        #expect(model.providers.isEmpty)
        let none = Recorder()
        await makeModel(none, methods: ["tts.speak"]).refresh()
        #expect(none.calls.isEmpty)
        #expect(!makeModel(none, methods: ["tts.speak"]).supportsStatus)
    }

    @Test func refreshReportsErrorAndKeepsGoing() async {
        let r = Recorder()
        r.errors["tts.status"] = rpc("UNAVAILABLE", "boom")
        r.replies["tts.providers"] = Fixtures.json(#"{"providers":[{"id":"openai","name":"OpenAI","configured":true}]}"#)
        let model = makeModel(r)
        await model.refresh()
        #expect(model.loadError == "boom" && model.providers.count == 1 && model.status == nil)
    }

    @Test func handleReconnectClears() async {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        let model = makeModel(r)
        await model.refresh()
        model.handleReconnect()
        #expect(model.status == nil && model.providers.isEmpty && model.personas.isEmpty && model.activePersona == nil && model.loadError == nil)
    }

    @Test func setProvider() async throws {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        r.replies["tts.setProvider"] = Fixtures.json(#"{"provider":"elevenlabs"}"#)
        let model = makeModel(r)
        await model.refresh()
        try await model.setProvider("elevenlabs")
        #expect(r.calls.last?.method == "tts.setProvider" && r.calls.last?.params == ["provider": "elevenlabs"])
        #expect(model.status?.provider == "elevenlabs")
    }

    @Test func setProviderErrorPropagatesAndKeepsState() async {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        r.errors["tts.setProvider"] = rpc("INVALID_REQUEST", "Invalid provider. Use a registered TTS provider id.")
        let model = makeModel(r)
        await model.refresh()
        await #expect(throws: GatewayError.self) { try await model.setProvider("nope") }
        #expect(model.status?.provider == "openai")
    }

    @Test func setPersonaAndClear() async throws {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        let model = makeModel(r)
        await model.refresh()
        r.replies["tts.setPersona"] = Fixtures.json(#"{"persona":"narrator"}"#)
        try await model.setPersona("narrator")
        #expect(r.calls.last?.params == ["persona": "narrator"] && model.activePersona == "narrator" && model.status?.persona == "narrator")
        r.replies["tts.setPersona"] = Fixtures.json(#"{"persona":null}"#)
        try await model.setPersona(nil)
        #expect(r.calls.last?.params == ["persona": "off"] && model.activePersona == nil && model.status?.persona == nil)
    }

    @Test func enableAndDisable() async throws {
        let r = Recorder()
        r.replies["tts.status"] = Fixtures.json(statusJSON)
        let model = makeModel(r)
        await model.refresh()
        r.replies["tts.enable"] = Fixtures.json(#"{"enabled":true}"#)
        try await model.setAutoSpeakChannels(true)
        #expect(r.calls.last?.method == "tts.enable" && model.status?.enabled == true && model.status?.auto == "always")
        r.replies["tts.disable"] = Fixtures.json(#"{"enabled":false}"#)
        try await model.setAutoSpeakChannels(false)
        #expect(r.calls.last?.method == "tts.disable" && model.status?.enabled == false && model.status?.auto == "off")
    }

    @Test func messageForErrors() {
        #expect(GatewayVoiceModel.message(rpc("INVALID_REQUEST", "Invalid persona. Use a configured TTS persona id.")) == "Invalid persona. Use a configured TTS persona id.")
        #expect(GatewayVoiceModel.message(rpc("UNKNOWN_METHOD", "x")) != "x")
    }
}
