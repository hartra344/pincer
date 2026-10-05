import Foundation

/// The actual Gateway Voice test completion path; publication precedes local playback.
@MainActor package final class VoiceTestCompletion {
    package init() {}
    package func invalidate() {}
    package func run(model: GatewayVoiceModel, sample: String,
                     publish: (TTSTestResult) -> Void, play: (TTSClip) -> Void) async {
        let outcome = await model.test(sample: sample)
        publish(outcome)
        if let clip = outcome.clip { play(clip) }
    }
}
