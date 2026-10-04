import Foundation
@testable import PincerKit

@MainActor
func runVoicePlaybackOwnershipChecks() {
    var ownership = VoicePlaybackOwnership()
    let a = ownership.begin()
    check(ownership.owns(a), "the current playback completion owns its player")
    let b = ownership.begin()
    check(!ownership.owns(a) && ownership.owns(b), "a queued old completion cannot stop a replacement")
    let newA = ownership.begin()
    check(!ownership.owns(a) && !ownership.owns(b) && ownership.owns(newA),
          "restarting the same voice creates a fresh ownership boundary")
    ownership.invalidate()
    check(!ownership.owns(newA), "explicit Stop invalidates queued completions")
    let preview = ownership.begin()
    let testClip = ownership.begin()
    check(!ownership.owns(preview) && ownership.owns(testClip), "Test clip replaces preview ownership")
    let nextPreview = ownership.begin()
    check(!ownership.owns(testClip) && ownership.owns(nextPreview), "a replacement preview invalidates an old Test clip loop")
}

@MainActor
func runDemoVoicePlaybackOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("playback ownership Demo connection", timeout: 25, {
        gateway.state.isConnected && gateway.bootstrapped
    }) else {
        check(false, "playback checks connect to the actual Demo Gateway")
        return
    }
    await gateway.voice.refresh()
    guard let provider = gateway.voice.providers.first(where: { !$0.voices.isEmpty }),
          let voice = provider.voices.first else {
        check(false, "actual Demo tts.providers supplies a voice for playback selection")
        return
    }
    check(!provider.id.isEmpty && !voice.isEmpty && gateway.voice.loadError == nil,
          "playback selection uses genuine loaded Demo voice metadata")
    // No audio is fetched here. Native AVPlayerItem tests exercise actual queued end
    // notifications; this check exercises the same production ownership with Demo data.
    var ownership = VoicePlaybackOwnership()
    let originalPreview = ownership.begin()
    let testClip = ownership.begin()
    check(!ownership.owns(originalPreview) && ownership.owns(testClip),
          "Test replaces the selected Demo voice preview without accepting its old completion")
    let restartedPreview = ownership.begin()
    check(!ownership.owns(originalPreview) && !ownership.owns(testClip) && ownership.owns(restartedPreview),
          "returning to the same Demo voice cannot revive either old playback token")
    ownership.invalidate()
    check(!ownership.owns(restartedPreview), "Stop rejects the current Demo preview's later completion")
}
