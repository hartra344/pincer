import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class HoldingPlayer: ReadAloudClipPlaying {
    var stops = 0
    private var waiting: CheckedContinuation<Bool, Never>?
    func play(_ clip: TTSClip) async -> Bool { await withCheckedContinuation { waiting = $0 } }
    func stop() { stops += 1; waiting?.resume(returning: true); waiting = nil }
}

@MainActor
private final class IdleSpeaker: ReadAloudLocalSpeaking {
    var spoken: [String] = []
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool { spoken.append(text); return true }
    func stop() {}
}

/// #412: interruptions, unplugged output and lock-screen stop end a read; nothing resumes on its own.
@Suite("Read Aloud system events")
@MainActor
struct ReadAloudSystemEventsTests {
    private func make(delay: Duration = .zero) -> (ReadAloudController, HoldingPlayer, IdleSpeaker, GatewayVoiceModel) {
        let player = HoldingPlayer(), speaker = IdleSpeaker()
        let controller = ReadAloudController(clipPlayer: player, localSpeaker: speaker, defaults: ScratchDefaults().defaults,
                                             gatewayTimeout: .seconds(30))
        let gateway = GatewayVoiceModel(methods: { nil }, scopes: { ["operator.write"] }, allowsWritesWithoutAdmin: false, request: { _, _ in
            try await Task.sleep(for: delay)
            return ["audioBase64": "AAEC", "provider": "openai", "mimeType": "audio/wav", "fileExtension": "wav"]
        })
        return (controller, player, speaker, gateway)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test(arguments: [ReadAloudSystemEvent.interruptionBegan, .oldDeviceUnavailable, .remoteStop, .backgroundTimeExpired])
    func eventWhileSpeakingGoesIdle(_ event: ReadAloudSystemEvent) async {
        let (controller, player, speaker, gateway) = make()
        controller.toggle(messageId: "m1", text: "Hello there.", gateway: gateway)
        #expect(await waitUntil { controller.phase == .speaking("m1") })
        controller.handle(event)
        #expect(controller.phase == .idle && controller.activeMessageId == nil && player.stops >= 1)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(controller.phase == .idle && speaker.spoken.isEmpty, "no fallback to the device voice, no auto-resume")
    }

    @Test func interruptionWhilePreparingCancelsTheFetch() async {
        let (controller, player, speaker, gateway) = make(delay: .milliseconds(150))
        controller.toggle(messageId: "m1", text: "Hello there.", gateway: gateway)
        #expect(controller.phase == .preparing("m1"))
        controller.handle(.interruptionBegan)
        #expect(controller.phase == .idle)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(controller.phase == .idle && speaker.spoken.isEmpty)
    }

    @Test func eventsWhileIdleAreNoOps() {
        let (controller, player, _, _) = make()
        for event in [ReadAloudSystemEvent.interruptionBegan, .oldDeviceUnavailable, .remoteStop, .backgroundTimeExpired] { controller.handle(event) }
        controller.handleAudioInterruptionBegan(); controller.handleRouteOldDeviceUnavailable(); controller.handleRemoteStop()
        #expect(controller.phase == .idle && player.stops == 0)
    }

    @Test func aNewReadStartsNormallyAfterAnInterruption() async {
        let (controller, _, _, gateway) = make()
        controller.toggle(messageId: "m1", text: "One.", gateway: gateway)
        #expect(await waitUntil { controller.phase == .speaking("m1") })
        controller.handleAudioInterruptionBegan()
        controller.toggle(messageId: "m2", text: "Two.", gateway: gateway)
        #expect(await waitUntil { controller.phase == .speaking("m2") })
        controller.handleRemoteStop()
        #expect(controller.phase == .idle)
    }

    @Test func nowPlayingTitleIsFlattenedAndCappedAt80() {
        #expect(ReadAloudController.nowPlayingTitle(for: "Hello\n\n  world") == "Hello world")
        let long = String(repeating: "word ", count: 40)
        let title = ReadAloudController.nowPlayingTitle(for: long)
        #expect(title.count == 81 && title.hasSuffix("…"))
        #expect(ReadAloudController.nowPlayingTitle(for: String(repeating: "a", count: 80)).count == 80)
    }
}
