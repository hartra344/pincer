import Foundation

/// Runs one Gateway Voice "Test voice" request and applies its result only if the page still owns it.
/// `invalidate()` (page Stop / disappear) or a newer `start` drops a pending result and its playback;
/// `finished` always runs once so the caller's busy state is released.
@MainActor package final class VoiceTestCompletion {
    private var generation: UInt64 = 0
    package init() {}
    package func invalidate() { self.generation &+= 1 }
    @discardableResult
    package func start(model: GatewayVoiceModel, sample: String,
                       publish: @escaping (TTSTestResult) -> Void, finished: @escaping () -> Void = {},
                       play: @escaping (TTSClip) -> Void) -> Task<Void, Never> {
        self.generation &+= 1
        let owner = self.generation
        return Task {
            defer { finished() }
            guard owner == self.generation, !Task.isCancelled else { return }
            let outcome = await model.test(sample: sample)
            guard owner == self.generation, !Task.isCancelled else { return }
            publish(outcome)
            if let clip = outcome.clip { play(clip) }
        }
    }
}
