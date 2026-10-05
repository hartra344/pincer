import Foundation

/// The actual Gateway Voice test completion path; publication precedes local playback.
@MainActor package final class VoiceTestCompletion {
    private var generation: UInt64 = 0
    package init() {}
    package func invalidate() { self.generation &+= 1 }
    package func run(model: GatewayVoiceModel, sample: String,
                     publish: (TTSTestResult) -> Void, play: (TTSClip) -> Void) async {
        self.generation &+= 1
        let owner = self.generation
        let outcome = await model.test(sample: sample)
        guard owner == self.generation, !Task.isCancelled else { return }
        publish(outcome)
        if let clip = outcome.clip { play(clip) }
    }
}
