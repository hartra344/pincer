#if DEBUG
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite(.timeLimit(.minutes(2)))
struct VoiceTestBusyCompletionTests {
    actor Gate {
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
    @Test
    func actualStoppedTestFinishesBusyCleanup() async throws {
        let stopped = true
        var busy = true
        let suite = "voice-page-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
        gateway.start(); gateway.reconnectIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !gateway.state.isConnected || gateway.hello == nil {
            try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        await gateway.voice.refresh()
        try #require(gateway.voice.canSpeak)
        let setup = VoiceSetupController()
        defer { setup.stop() }
        var results: [TTSTestResult] = [], clips: [TTSClip] = []
        setup.testPlaybackOverride = { clips.append($0) }
        let gate = Gate()
        await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
        let task = Task { await setup.testVoice(model: gateway.voice, sample: "Owned voice test", finished: { busy = false }) { results.append($0) } }
        do {
            let held = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await gate.entered) { try Task.checkCancellation(); try #require(ContinuousClock.now < held); try await Task.sleep(for: .milliseconds(10)) }
            if stopped { setup.stop() } // Same method called by VoiceSettingsPage.onDisappear.
            await gate.release(); await task.value
            #expect(!busy, "actual controller completion releases the View busy state even when publication is rejected")
            #expect(results.count == (stopped ? 0 : 1))
            #expect(clips.count == (stopped ? 0 : 1))
            if !stopped { let clip = try #require(results.first?.clip); #expect(!clip.data.isEmpty && clips.first?.data == clip.data) }
        } catch { task.cancel(); await gate.release(); await task.value; await gateway.connection.setDemoResponseDelivery(nil); throw error }
        await gateway.connection.setDemoResponseDelivery(nil)
    }
}
#endif
