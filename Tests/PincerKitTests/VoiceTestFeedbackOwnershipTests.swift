import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Actual voice test feedback ownership", .serialized)
struct VoiceTestFeedbackOwnershipTests {
    enum Change: String, CaseIterable, Sendable { case key, model, voice, reconnect }
    @MainActor private final class Server {
        var entered = false
        var patches = 0
        var rejectPatch = false
        var config: JSONValue = ["tts": ["providers": ["elevenlabs": ["modelId": "eleven_v3", "voiceId": "old-voice"]]]]
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        let fallback: Bool
        init(fallback: Bool) { self.fallback = fallback }
        func release() { released = true; waiter?.resume(); waiter = nil }
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            switch method {
            case "tts.status": return ["provider": "elevenlabs", "providerStates": [["id": "elevenlabs", "label": "ElevenLabs", "configured": true]]]
            case "tts.providers": return ["providers": []]
            case "tts.personas": return ["personas": []]
            case "config.get": return ["resolved": config, "hash": "fixture-hash", "valid": true]
            case "config.patch":
                patches += 1
                if rejectPatch { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Save failed", details: nil) }
                config = config.applyingMergePatch(try JSONValue.decode(Data(try #require(params["raw"]?.text).utf8)))
                #expect(params["baseHash"]?.text == "fixture-hash")
                return ["ok": true]
            case "tts.speak":
                #expect(params["text"]?.text == "Feedback fixture")
                entered = true
                if !released { await withCheckedContinuation { waiter = $0 } }
                if fallback { return ["audioBase64": "AAEC", "provider": "openai", "mimeType": "audio/wav", "fileExtension": "wav"] }
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "Old voice synthesis failed", details: nil)
            default: Issue.record("Unexpected existing voice method: \(method)"); return [:]
            }
        }
    }
    private func model(_ server: Server) -> GatewayVoiceModel {
        let methods: Set<String> = ["tts.status", "tts.providers", "tts.personas", "tts.speak", "config.get", "config.patch"]
        return GatewayVoiceModel(methods: { methods }, request: { try await server.request($0, $1) })
    }
    private func waitForAdmission(_ server: Server) async throws {
        while !server.entered { try Task.checkCancellation(); await Task.yield() }
    }
    @Test(.timeLimit(.minutes(2)), arguments: Change.allCases, [false, true])
    func obsoleteActualTestCannotRestoreFeedbackAfterConfigurationChange(_ change: Change, _ fallback: Bool) async throws {
        let server = Server(fallback: fallback), model = self.model(server)
        await model.refresh()
        let held = Task { await model.test(sample: "Feedback fixture") }
        defer { held.cancel(); server.release() }
        try await waitForAdmission(server)
        switch change {
        case .key: _ = try await model.saveKey("new-fixture-key", provider: "elevenlabs")
        case .model: _ = try await model.saveModel("eleven_flash_v2_5", provider: "elevenlabs")
        case .voice: _ = try await model.saveVoice("new-voice", provider: "elevenlabs")
        case .reconnect: model.handleReconnect()
        }
        #expect(server.patches == (change == .reconnect ? 0 : 1))
        try #require(model.lastTestError["elevenlabs"] == nil)
        server.release()
        let outcome = await held.value
        if fallback {
            if case .fellBack = outcome.outcome {} else { Issue.record("Actual old request must retain fallback return") }
        } else { #expect(outcome.outcome == .failed("Old voice synthesis failed")) }
        #expect(model.lastTestError["elevenlabs"] == nil,
                "Old request must not restore feedback for replaced configuration or connection")
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func unchangedActualTestStillPublishesCurrentFailureOrFallback(_ fallback: Bool) async throws {
        let server = Server(fallback: fallback), model = self.model(server)
        await model.refresh()
        let held = Task { await model.test(sample: "Feedback fixture") }
        defer { held.cancel(); server.release() }
        try await waitForAdmission(server)
        server.release()
        _ = await held.value
        #expect(model.lastTestError["elevenlabs"] != nil)
        #expect(server.patches == 0)
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func failedOrUnrelatedSaveDoesNotInvalidateCurrentFeedback(_ failed: Bool) async throws {
        let server = Server(fallback: false), model = self.model(server)
        await model.refresh()
        let held = Task { await model.test(sample: "Feedback fixture") }
        defer { held.cancel(); server.release() }
        try await waitForAdmission(server)
        if failed {
            server.rejectPatch = true
            do { _ = try await model.saveVoice("new", provider: "elevenlabs"); Issue.record("Expected failed save") } catch {}
        } else { _ = try await model.saveVoice("unrelated", provider: "openai") }
        server.release(); _ = await held.value
        #expect(model.lastTestError["elevenlabs"] == "Old voice synthesis failed")
        #expect(model.voiceTestOwners.isEmpty)
    }
    @Test(.timeLimit(.minutes(2)))
    func canceledCurrentTestDoesNotPublishFeedback() async throws {
        let server = Server(fallback: false), model = self.model(server)
        await model.refresh()
        let held = Task { await model.test(sample: "Feedback fixture") }
        defer { held.cancel(); server.release() }
        try await waitForAdmission(server)
        held.cancel(); server.release(); _ = await held.value
        #expect(model.lastTestError["elevenlabs"] == nil && model.voiceTestOwners.isEmpty)
    }
    @Test(.timeLimit(.minutes(2)))
    func preCanceledAdmissionCannotDisplaceHealthyHeldTest() async throws {
        let server = Server(fallback: false), model = self.model(server)
        await model.refresh()
        let held = Task { await model.test(sample: "Feedback fixture") }
        defer { held.cancel(); server.release() }
        try await waitForAdmission(server)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.test(sample: "Feedback fixture")
        }
        _ = await canceled.value
        server.release(); _ = await held.value
        #expect(model.lastTestError["elevenlabs"] == "Old voice synthesis failed")
        #expect(model.voiceTestOwners.isEmpty)
    }
}
