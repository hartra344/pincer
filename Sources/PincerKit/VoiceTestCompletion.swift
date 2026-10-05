import Foundation

/// The actual Gateway Voice test completion path; publication precedes local playback.
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
        return Task { await self.runOwned(owner: owner, model: model, sample: sample, publish: publish, finished: finished, play: play) }
    }
    package func run(model: GatewayVoiceModel, sample: String,
                     publish: (TTSTestResult) -> Void, finished: () -> Void = {}, play: (TTSClip) -> Void) async {
        self.generation &+= 1
        await self.runOwned(owner: self.generation, model: model, sample: sample, publish: publish, finished: finished, play: play)
    }
    private func runOwned(owner: UInt64, model: GatewayVoiceModel, sample: String,
                          publish: (TTSTestResult) -> Void, finished: () -> Void, play: (TTSClip) -> Void) async {
        defer { finished() }
        guard owner == self.generation, !Task.isCancelled else { return }
        let outcome = await model.test(sample: sample)
        guard owner == self.generation, !Task.isCancelled else { return }
        publish(outcome)
        if let clip = outcome.clip { play(clip) }
    }
}
