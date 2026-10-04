import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Actual voice-list request ownership", .serialized)
struct VoiceListRequestOwnershipTests {
    @MainActor
    private final class Lists {
        var entered: Set<String> = []
        private var waiters: [String: CheckedContinuation<[ElevenLabsVoice], Never>] = [:]
        private var results: [String: [ElevenLabsVoice]] = [:]
        func load(_ key: String?) async -> [ElevenLabsVoice] {
            let key = key ?? "nil"
            entered.insert(key)
            return await withCheckedContinuation { waiter in
                if let result = results[key] { waiter.resume(returning: result) }
                else { waiters[key] = waiter }
            }
        }
        func release(_ key: String, _ voices: [ElevenLabsVoice]) {
            results[key] = voices
            waiters.removeValue(forKey: key)?.resume(returning: voices)
        }
        func releaseAll() {
            let held = waiters
            waiters = [:]
            for waiter in held.values { waiter.resume(returning: []) }
        }
        func waitFor(_ key: String) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !entered.contains(key) {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < deadline, "Actual voice list request did not enter")
                await Task.yield()
            }
        }
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func olderActualListCannotOverwriteNewerCatalogOrSessionKey(_ cancelOld: Bool) async throws {
        let lists = Lists()
        let model = GatewayVoiceModel(request: { _, _ in Issue.record("Voice catalog must not invent Gateway RPCs"); return [:] })
        model.voiceLister = { await lists.load($0) }
        let old = Task { try? await model.listElevenLabsVoices(apiKey: "fixture-old-key") }
        defer { old.cancel(); lists.releaseAll() }
        try await lists.waitFor("fixture-old-key")
        let newest = Task { try? await model.listElevenLabsVoices(apiKey: "fixture-new-key") }
        defer { newest.cancel(); lists.releaseAll() }
        try await lists.waitFor("fixture-new-key")
        let latest = [ElevenLabsVoice(id: "new-account-voice", name: "New account")]
        lists.release("fixture-new-key", latest)
        _ = await newest.value
        try #require(model.voices == latest && model.sessionKeys["elevenlabs"] == "fixture-new-key")
        if cancelOld { old.cancel() }
        // An injected asynchronous dependency may finish even after caller cancellation.
        // This is the actual model publication boundary, not a mirrored save operation.
        lists.release("fixture-old-key", [ElevenLabsVoice(id: "old-account-voice", name: "Old account")])
        _ = await old.value
        #expect(model.voices == latest, "Older completion must not replace the latest voice catalog")
        #expect(model.sessionKeys["elevenlabs"] == "fixture-new-key",
                "Older completion must not restore a previous account's session key")
    }
    @Test(.timeLimit(.minutes(2)))
    func currentSingleLoadAndUnderlyingCancellationKeepExistingSemantics() async throws {
        let model = GatewayVoiceModel(request: { _, _ in Issue.record("Voice list uses its existing dependency"); return [:] })
        let voices = [ElevenLabsVoice(id: "current", name: "Current voice")]
        model.voiceLister = { key in
            #expect(key == "fixture-current-key")
            return voices
        }
        let returned = try await model.listElevenLabsVoices(apiKey: "fixture-current-key")
        #expect(returned == voices && model.voices == voices)
        #expect(model.sessionKeys["elevenlabs"] == "fixture-current-key")
        model.voiceLister = { _ in throw CancellationError() }
        do {
            _ = try await model.listElevenLabsVoices(apiKey: "fixture-canceled-key")
            Issue.record("Actual underlying cancellation must propagate")
        } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error type") }
        #expect(model.voices == voices && model.sessionKeys["elevenlabs"] == "fixture-current-key",
                "A failed current request does not clear the previously loaded catalog or key")
    }
}
