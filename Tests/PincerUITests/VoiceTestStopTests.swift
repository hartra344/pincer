#if DEBUG
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #918: Stop (VoiceSettingsPage.onDisappear) must drop a pending Test voice result and its playback,
/// whether the request is still queued or already in flight, and still release the busy state once.
@MainActor @Suite(.timeLimit(.minutes(2)))
struct VoiceTestStopTests {
    enum StopAt: CaseIterable { case never, queued, inFlight }

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

    @Test(arguments: StopAt.allCases)
    func stopDropsPendingTestResult(stopAt: StopAt) async throws {
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
        var results: [TTSTestResult] = [], clips: [TTSClip] = [], finishedCount = 0
        setup.testPlaybackOverride = { clips.append($0) }
        let gate = Gate()
        await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
        defer { Task { await gateway.connection.setDemoResponseDelivery(nil) } }

        let task = setup.startTestVoice(model: gateway.voice, sample: "Owned voice test", finished: { finishedCount += 1 }) { results.append($0) }
        switch stopAt {
        case .never: break
        case .queued: setup.stop()
        case .inFlight:
            let held = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await gate.entered) {
                if ContinuousClock.now >= held { task.cancel(); await gate.release(); await task.value; Issue.record("tts.speak never sent"); return }
                try await Task.sleep(for: .milliseconds(10))
            }
            setup.stop()
        }
        await gate.release(); await task.value

        let stopped = stopAt != .never
        #expect(finishedCount == 1)
        #expect(results.count == (stopped ? 0 : 1))
        #expect(clips.count == (stopped ? 0 : 1))
        if !stopped { let clip = try #require(results.first?.clip); #expect(!clip.data.isEmpty && clips.first?.data == clip.data) }
    }
}
#endif
