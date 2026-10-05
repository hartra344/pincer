#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkVoiceQueuedCompletion() async {
    for stopped in [false, true] {
        let (defaults, suite) = scratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
        gateway.start(); gateway.reconnectIfNeeded()
        guard await waitFor("voice page Demo", timeout: 25, { gateway.state.isConnected && gateway.hello != nil }) else { check(false, "actual Demo ready"); return }
        await gateway.voice.refresh()
        guard gateway.voice.canSpeak else { check(false, "actual Demo voice can speak"); return }
        let completion = VoiceTestCompletion()
        var results: [TTSTestResult] = [], clips: [TTSClip] = []
        var finishedCount = 0
        let task = completion.start(model: gateway.voice, sample: "Owned voice test", publish: { results.append($0) }, finished: { finishedCount += 1 }, play: { clips.append($0) })
        if stopped { completion.invalidate() }
        await task.value
        check(finishedCount == 1, "actual queued test completes cleanup exactly once")
        check(results.count == (stopped ? 0 : 1) && clips.count == (stopped ? 0 : 1), "shared shipped completion honors page invalidation; UI hook covered by UI tests")
        if !stopped { check(results.first?.clip?.data.isEmpty == false && results.first?.clip?.data == clips.first?.data, "actual ordinary full clip published and admitted") }
    }
}
@MainActor func runVoiceTestQueuedAdmissionChecks() async { await checkVoiceQueuedCompletion() }
@MainActor func runDemoVoiceTestQueuedAdmissionChecks() async { await checkVoiceQueuedCompletion() }
#endif
