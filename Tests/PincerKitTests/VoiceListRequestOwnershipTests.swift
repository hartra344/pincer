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
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func reconnectOrCurrentCancellationRejectsHeldPublication(_ reconnect: Bool) async throws {
        let lists = Lists()
        let model = GatewayVoiceModel(request: { _, _ in [:] })
        model.voiceLister = { await lists.load($0) }
        let task = Task { () -> Bool in
            do { _ = try await model.listElevenLabsVoices(apiKey: "held-key"); return false }
            catch is CancellationError { return true }
            catch { Issue.record("Unexpected obsolete publication error"); return false }
        }
        defer { task.cancel(); lists.releaseAll() }
        try await lists.waitFor("held-key")
        if reconnect { model.handleReconnect() } else { task.cancel() }
        lists.release("held-key", [ElevenLabsVoice(id: "obsolete", name: "Obsolete")])
        #expect(await task.value, "Obsolete or canceled actual requests must not return a usable catalog")
        #expect(model.voices.isEmpty && model.sessionKeys["elevenlabs"] == nil)
    }
    @Test(.timeLimit(.minutes(2)))
    func latestFailurePreservesPreviouslyPublishedCatalogWithoutRevivingOlderRequest() async throws {
        let model = GatewayVoiceModel(request: { _, _ in [:] })
        let seed = [ElevenLabsVoice(id: "seed", name: "Previously loaded")]
        model.voiceLister = { _ in seed }
        _ = try await model.listElevenLabsVoices(apiKey: "seed-key")
        let lists = Lists()
        model.voiceLister = { key in
            if key == "latest-invalid" { throw TTSSetupError.invalidKey }
            return await lists.load(key)
        }
        let old = Task { () -> Bool in
            do { _ = try await model.listElevenLabsVoices(apiKey: "older-key"); return false }
            catch is CancellationError { return true }
            catch { Issue.record("Unexpected older request error"); return false }
        }
        defer { old.cancel(); lists.releaseAll() }
        try await lists.waitFor("older-key")
        do { _ = try await model.listElevenLabsVoices(apiKey: "latest-invalid"); Issue.record("Latest invalid key must fail") }
        catch TTSSetupError.invalidKey {} catch { Issue.record("Latest failure must preserve its actual error") }
        lists.release("older-key", [ElevenLabsVoice(id: "older", name: "Older")])
        #expect(await old.value)
        #expect(model.voices == seed && model.sessionKeys["elevenlabs"] == "seed-key")
    }

    enum KeyMutation: String, CaseIterable, Sendable { case saveSuccess, savePersistedFailure, removeDeleteFailure }
    @Test(.timeLimit(.minutes(2)), arguments: KeyMutation.allCases)
    func acceptedKeyMutationInvalidatesEarlierAndMidMutationCatalogs(_ mode: KeyMutation) async throws {
        var config: JSONValue = ["tts": ["providers": ["elevenlabs": ["apiKey": ["source": "store", "provider": "default", "id": "ELEVENLABS_API_KEY"]]]]]
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        let methods: Set<String> = ["config.get", "config.patch", "secrets.store.delete"]
        let model = GatewayVoiceModel(methods: { methods }, request: { method, params in
            switch method {
            case "config.get": return ["resolved": config, "hash": "key-before", "valid": true]
            case "config.patch":
                entered = true
                await withCheckedContinuation { release = $0 }
                let patch = try JSONValue.decode(Data(try #require(params["raw"]?.text).utf8))
                config = config.applyingMergePatch(patch)
                if mode == .savePersistedFailure {
                    throw GatewayError.rpc(code: "UNAVAILABLE", message: "Saved, restart failed",
                        details: ["persistedConfig": ["config": config, "hash": "key-persisted"]])
                }
                return ["ok": true]
            case "secrets.store.delete": throw GatewayError.rpc(code: "UNAVAILABLE", message: "Secret deletion unavailable", details: nil)
            default: Issue.record("Unexpected key mutation method"); return [:]
            }
        })
        await model.refresh()
        let seed = [ElevenLabsVoice(id: "seed-key-mutation", name: "Previously loaded")]
        model.voiceLister = { _ in seed }
        _ = try await model.listElevenLabsVoices(apiKey: "seed-key")
        let lists = Lists()
        model.voiceLister = { await lists.load($0) }
        func request(_ key: String) -> Task<Bool, Never> {
            Task {
                do { _ = try await model.listElevenLabsVoices(apiKey: key); return false }
                catch is CancellationError { return true }
                catch { Issue.record("Unexpected obsolete catalog error"); return false }
            }
        }
        let old = request("before-mutation")
        defer { old.cancel(); lists.releaseAll() }
        try await lists.waitFor("before-mutation")
        let mutation = Task { () -> Bool in
            do {
                if mode == .removeDeleteFailure { _ = try await model.removeKey(provider: "elevenlabs") }
                else { _ = try await model.saveKey("new-key", provider: "elevenlabs") }
                return true
            } catch { return false }
        }
        defer { mutation.cancel(); release?.resume(); release = nil }
        let deadline = ContinuousClock.now + .seconds(15)
        while !entered { try #require(ContinuousClock.now < deadline); await Task.yield() }
        lists.release("before-mutation", [ElevenLabsVoice(id: "old", name: "Old")])
        let oldRejected = await old.value
        #expect(oldRejected && model.voices == seed && model.sessionKeys["elevenlabs"] == "seed-key",
                "Mutation admission rejects an older catalog before any newer list starts")
        let during = request("during-mutation")
        defer { during.cancel(); lists.releaseAll() }
        try await lists.waitFor("during-mutation")
        let waiter = release; release = nil; waiter?.resume()
        let succeeded = await mutation.value
        #expect(succeeded == (mode == .saveSuccess))
        lists.release("during-mutation", [ElevenLabsVoice(id: "mid", name: "Mid")])
        let midRejected = await during.value
        #expect(midRejected)
        #expect(model.voices == seed)
        #expect(model.sessionKeys["elevenlabs"] == (mode == .saveSuccess ? "new-key" : "seed-key"),
                "Obsolete catalog must not replace mutation-owned session key state, including failure")
    }

}
