#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor private final class StopRecordingSpeaker: ReadAloudLocalSpeaking {
    var samples: [String] = []
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool { samples.append(text); return true }
    func stop() {}
}
@MainActor @Suite(.timeLimit(.minutes(2)))
struct DeviceVoiceStopTests {
    @Test(arguments: [0, 1, 2])
    func actualQueuedTestHonorsCurrentIntent(mode: Int) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let speaker = StopRecordingSpeaker()
        let controller = ReadAloudController(localSpeaker: speaker, defaults: scratch.defaults)
        defer { controller.stop() }
        controller.testDeviceVoice("First sample")
        let first = try #require(controller.deviceVoiceTaskForTesting)
        var latest: Task<Void, Never>?
        if mode == 1 { controller.stop() }
        if mode == 2 { controller.testDeviceVoice("Latest sample"); latest = try #require(controller.deviceVoiceTaskForTesting) }
        await first.value
        if let latest { await latest.value }
        #expect(speaker.samples == (mode == 0 ? ["First sample"] : mode == 1 ? [] : ["Latest sample"]))
        #expect(!controller.isActive)
    }
}
#endif
