import Foundation
@testable import PincerKit

@MainActor
private func checkVoiceCatalogOwnership(_ voices: [ElevenLabsVoice]) async {
    let model = GatewayVoiceModel(request: { _, _ in [:] })
    model.voiceLister = { _ in voices }
    do {
        let result = try await model.listElevenLabsVoices(apiKey: "checks-fixture-key")
        check(result == voices && model.voices == voices, "actual current voice-list request publishes its catalog")
        check(model.sessionKeys["elevenlabs"] == "checks-fixture-key", "current catalog keeps its matching session key")
        var release: CheckedContinuation<[ElevenLabsVoice], Never>?
        model.voiceLister = { _ in await withCheckedContinuation { release = $0 } }
        let pending = Task { () -> Bool in
            do { _ = try await model.listElevenLabsVoices(apiKey: "obsolete-fixture-key"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        defer { pending.cancel(); release?.resume(returning: []); release = nil }
        let entered = await waitFor("held actual catalog request") { release != nil }
        check(entered, "actual voice-list dependency admits held request")
        guard entered else { return }
        model.handleReconnect()
        let waiter = release; release = nil
        waiter?.resume(returning: [ElevenLabsVoice(id: "obsolete", name: "Obsolete")])
        let rejected = await pending.value
        check(rejected, "reconnect invalidates a held catalog return")
        check(model.voices == voices && model.sessionKeys["elevenlabs"] == "checks-fixture-key",
              "obsolete completion preserves prior catalog and key")
    } catch { check(false, "current catalog control failed") }
}

@MainActor func runVoiceListRequestOwnershipChecks() async {
    await checkVoiceCatalogOwnership([ElevenLabsVoice(id: "checks-current", name: "Current")])
}
@MainActor func runDemoVoiceListRequestOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("voice catalog Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "Demo voice catalog connects"); return
    }
    await gateway.voice.refresh()
    guard let id = gateway.voice.providers.first(where: { !$0.voices.isEmpty })?.voices.first else {
        check(false, "actual tts.providers supplies voice metadata"); return
    }
    check(!id.isEmpty && gateway.voice.loadError == nil, "genuine Demo supplies catalog metadata without ElevenLabs network")
    // ElevenLabs HTTP is replaced by its established injectable dependency; Gateway metadata
    // above comes from the real connected Demo, not an invented Gateway voice-list method.
    await checkVoiceCatalogOwnership([ElevenLabsVoice(id: id, name: id)])
}
