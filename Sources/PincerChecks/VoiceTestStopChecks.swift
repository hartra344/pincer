#if DEBUG
import Foundation
@testable import PincerKit

private actor VoiceTestGate {
    var entered = false, released = false
    var waiter: CheckedContinuation<Void, Never>?
    func hold(_ method: String) async {
        guard method == "tts.speak" else { return }
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in if released { c.resume() } else { waiter = c } }
        } onCancel: { Task { await self.release() } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

/// #918: a stopped Gateway Voice test (queued or in flight) publishes nothing and plays nothing,
/// and still runs its cleanup exactly once.
@MainActor func runVoiceTestStopChecks() async {
    for stopAt in ["never", "queued", "in flight"] {
        let (defaults, suite) = scratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
        gateway.start(); gateway.reconnectIfNeeded()
        guard await waitFor("voice test Demo", timeout: 25, { gateway.state.isConnected && gateway.hello != nil }) else { check(false, "voice test: Demo ready"); return }
        await gateway.voice.refresh()
        guard gateway.voice.canSpeak else { check(false, "voice test: Demo voice can speak"); return }

        let completion = VoiceTestCompletion()
        var results: [TTSTestResult] = [], clips: [TTSClip] = [], finishedCount = 0
        let gate = VoiceTestGate()
        await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
        let task = completion.start(model: gateway.voice, sample: "Owned voice test",
                                    publish: { results.append($0) }, finished: { finishedCount += 1 }, play: { clips.append($0) })
        if stopAt == "queued" { completion.invalidate() }
        if stopAt == "in flight" {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await gate.entered), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            let entered = await gate.entered
            check(entered, "voice test: tts.speak in flight")
            completion.invalidate()
        }
        await gate.release(); await task.value
        await gateway.connection.setDemoResponseDelivery(nil)

        let stopped = stopAt != "never"
        check(finishedCount == 1, "voice test (stop \(stopAt)): cleanup runs exactly once")
        check(results.count == (stopped ? 0 : 1) && clips.count == (stopped ? 0 : 1),
              "voice test (stop \(stopAt)): result/playback admitted only while the page owns it")
        if !stopped { check(results.first?.clip?.data.isEmpty == false && results.first?.clip?.data == clips.first?.data, "voice test: ordinary result plays its clip") }
    }
}
#endif
