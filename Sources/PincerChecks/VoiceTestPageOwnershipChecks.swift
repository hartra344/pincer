#if DEBUG
import Foundation
@testable import PincerKit

private actor VoicePageGate {
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
@MainActor private func checkVoicePageCompletion() async {
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
        let gate = VoicePageGate()
        await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
        let task = Task { await completion.run(model: gateway.voice, sample: "Owned voice test", publish: { results.append($0) }, play: { clips.append($0) }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await gate.entered) && !Task.isCancelled && ContinuousClock.now < deadline { do { try await Task.sleep(for: .milliseconds(10)) } catch { break } }
        guard await gate.entered else { check(false, "actual computed speak result held"); task.cancel(); await gate.release(); await task.value; await gateway.connection.setDemoResponseDelivery(nil); return }
        if stopped { completion.invalidate() }
        await gate.release(); await task.value
        await gateway.connection.setDemoResponseDelivery(nil)
        check(results.count == (stopped ? 0 : 1) && clips.count == (stopped ? 0 : 1), "shared shipped completion honors page invalidation; UI hook covered by UI tests")
        if !stopped { check(results.first?.clip?.data.isEmpty == false && results.first?.clip?.data == clips.first?.data, "actual ordinary full clip published and admitted") }
    }
}
@MainActor func runVoiceTestPageOwnershipChecks() async { await checkVoicePageCompletion() }
@MainActor func runDemoVoiceTestPageOwnershipChecks() async { await checkVoicePageCompletion() }
#endif
