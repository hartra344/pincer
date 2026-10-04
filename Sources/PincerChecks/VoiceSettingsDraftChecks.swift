import Foundation
@testable import PincerKit

@MainActor
func runVoiceSettingsDraftChecks() {
    let draft = VoiceSettingsDraft()
    var firstValue = TTSVoiceSettings.elevenLabsDefault
    firstValue.speed = 1.5
    draft.edit(firstValue)
    guard let first = draft.commit() else { check(false, "actual voice draft admits a released change"); return }
    var middle = firstValue; middle.speed = 1.2
    draft.edit(middle)
    check(draft.commit() == nil, "a second release queues behind the active voice save")
    var latest = firstValue; latest.speed = 1.7
    draft.edit(latest)
    check(draft.commit() == nil && draft.activeCount == 1 && draft.pendingCount == 1,
          "actual voice queue retains one active and only the latest committed snapshot")
    var unreleased = latest; unreleased.stability = 0.8
    draft.edit(unreleased)
    guard let next = draft.complete(first, acknowledged: first.value) else {
        check(false, "first voice acknowledgment admits the latest queued release"); return
    }
    check(next.value == latest && draft.value == unreleased,
          "actual voice submission separates committed settings from a newer unreleased drag")
    check(draft.complete(first, acknowledged: first.value) == nil && draft.activeCount == 1,
          "an old repeated completion cannot release the current voice submission")
    _ = draft.complete(next, acknowledged: next.value)
    check(draft.baseline == latest && draft.value == unreleased && draft.activeCount == 0,
          "latest accepted voice settings advance saved baseline without replacing a newer draft")
    let failed = VoiceSettingsDraft()
    failed.edit(firstValue)
    if let submission = failed.commit() {
        _ = failed.complete(submission, acknowledged: nil)
        check(failed.baseline == .elevenLabsDefault && failed.value == firstValue && failed.commit()?.value == firstValue,
              "a failed voice save keeps unsaved settings available for retry")
    } else { check(false, "failure control admits actual voice settings") }
    let restoring = VoiceSettingsDraft()
    restoring.edit(firstValue)
    if let submitted = restoring.commit() {
        restoring.edit(.elevenLabsDefault)
        _ = restoring.commit()
        let restore = restoring.complete(submitted, acknowledged: nil)
        check(restore?.value == .elevenLabsDefault && restoring.activeCount == 1,
              "a possibly persisted failed save still sends an explicitly queued restore to the old baseline")
        if let restore { _ = restoring.complete(restore, acknowledged: restore.value) }
    } else { check(false, "persisted-failure control admits changed voice settings") }
    let operations = VoiceSetupOperationTracker()
    let older = operations.begin(), newer = operations.begin()
    check(!operations.finish(older) && operations.busy && operations.activeCount == 1,
          "older operation completion retains pending work and cannot publish its outcome")
    check(operations.finish(newer) && !operations.busy,
          "only the latest operation owns its terminal notice or error")
}

@MainActor
private final class VoiceResponseGate {
    var patches: [JSONValue] = []
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var allReleased = false
    func hold(_ patch: JSONValue) async {
        let index = self.patches.count
        self.patches.append(patch)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.allReleased || self.released.contains(index) || Task.isCancelled { continuation.resume() }
                else { self.waiters[index] = continuation }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.releaseAll() } }
    }
    func release(_ index: Int) {
        self.released.insert(index)
        self.waiters.removeValue(forKey: index)?.resume()
    }
    func releaseAll() {
        self.allReleased = true
        let waiters = self.waiters.values
        self.waiters = [:]
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
func runDemoVoiceSettingsDraftChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    guard await waitFor("voice draft Demo connection", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "voice draft checks connect to actual Demo Gateway"); return
    }
    var deniedPatches = 0
    let limited = GatewayVoiceModel(scopes: { gateway.hello?.scopes ?? [] }, request: { method, params in
        if method == "config.patch" { deniedPatches += 1 }
        return try await gateway.connection.request(method, params)
    })
    do {
        _ = try await limited.saveVoiceSettings(.elevenLabsDefault, provider: "elevenlabs")
        check(false, "non-admin actual Demo scopes reject voice configuration")
    } catch {
        check(gateway.hello?.scopes.contains(GatewayConnection.adminScope) == false
              && (error as? ConfigWriteError) == .adminRequired && deniedPatches == 0,
              "genuine non-admin Demo authorization rejects voice Save before any config.patch")
    }
    // Simulate an admin-authorized client with the existing model dependency seam. The real
    // Demo hello stays non-admin and all actual protocol requests are forwarded unchanged.
    let gate = VoiceResponseGate()
    let model = GatewayVoiceModel(scopes: { [GatewayConnection.adminScope] }, request: { method, params in
        let result = try await gateway.connection.request(method, params)
        if method == "config.patch" {
            guard let raw = params["raw"]?.text else { throw ConfigWriteError.other("Missing actual voice patch") }
            let patch = try JSONValue.decode(Data(raw.utf8))
            await gate.hold(patch)
        }
        return result
    })
    await model.refresh()
    let original = model.setups["elevenlabs"]?.voiceSettings ?? .elevenLabsDefault
    let draft = VoiceSettingsDraft(initial: original)
    var firstValue = original; firstValue.speed = original.speed == 1.5 ? 1.4 : 1.5
    draft.edit(firstValue)
    guard let first = draft.commit() else { check(false, "actual voice draft admits the connected first save"); return }
    var completed = false
    var saveFailure: String?
    let saving = Task { @MainActor in
        var current: VoiceSettingsDraft.Submission? = first
        while let submission = current {
            do {
                _ = try await model.saveVoiceSettings(submission.value, provider: "elevenlabs")
                current = draft.complete(submission, acknowledged: model.setups["elevenlabs"]?.voiceSettings)
            } catch {
                saveFailure = GatewayVoiceModel.message(error)
                current = draft.complete(submission, acknowledged: nil)
            }
        }
        completed = true
    }
    defer { saving.cancel(); gate.releaseAll() }
    guard await waitFor("held actual first voice response", { gate.patches.count == 1 || completed }), gate.patches.count == 1 else {
        check(false, "actual first voice config.patch reaches held response: \(saveFailure ?? "no response")"); return
    }
    var middle = firstValue; middle.speed = 1.2
    draft.edit(middle); _ = draft.commit()
    var latest = firstValue; latest.speed = 1.7
    draft.edit(latest); _ = draft.commit()
    var unreleased = latest; unreleased.stability = original.stability == 0.8 ? 0.7 : 0.8
    draft.edit(unreleased)
    check(gate.patches.count == 1 && draft.activeCount == 1 && draft.pendingCount == 1,
          "actual connected voice saves retain only first RPC plus latest queued release")
    gate.release(0)
    guard await waitFor("held actual latest voice response", { gate.patches.count == 2 || completed }), gate.patches.count == 2 else {
        check(false, "actual queued latest voice reaches second config.patch: \(saveFailure ?? "no response")"); return
    }
    check(gate.patches[1]["tts"]?["providers"]?["elevenlabs"]?["voiceSettings"] == latest.json,
          "actual Demo second wire patch contains latest committed settings and excludes unreleased drag")
    gate.release(1)
    await saving.value
    check(saveFailure == nil && gate.patches.count == 2 && model.setups["elevenlabs"]?.voiceSettings == latest,
          "actual Demo acknowledges first and latest voice settings exactly once")
    check(draft.baseline == latest && draft.value == unreleased && draft.activeCount == 0 && draft.pendingCount == 0,
          "connected voice acknowledgment preserves current unreleased local slider intent")
    gate.releaseAll()
    do {
        _ = try await model.saveVoiceSettings(original, provider: "elevenlabs")
        check(model.setups["elevenlabs"]?.voiceSettings == original,
              "actual Demo voice settings are restored through the same verified save path")
    } catch { check(false, "actual Demo voice restoration failed: \(GatewayVoiceModel.message(error))") }
}
