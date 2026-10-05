#if DEBUG
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite(.timeLimit(.minutes(2)))
struct VoiceTestQueuedAdmissionTests {
    @Test(arguments: [false, true])
    func actualQueuedTestHonorsPageStop(stopped: Bool) async throws {
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
        var finishedCount = 0
        let task = setup.startTestVoice(model: gateway.voice, sample: "Owned voice test", finished: { finishedCount += 1 }) { results.append($0) }
        if stopped { setup.stop() }
        await task.value
        #expect(finishedCount == 1)
        #expect(results.count == (stopped ? 0 : 1))
        #expect(clips.count == (stopped ? 0 : 1))
        if !stopped { let clip = try #require(results.first?.clip); #expect(!clip.data.isEmpty && clips.first?.data == clip.data) }

        await gateway.connection.setDemoResponseDelivery(nil)
    }
}
#endif
