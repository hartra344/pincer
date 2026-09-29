import AVFoundation
import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class FakeClipPlayer: ReadAloudClipPlaying {
    var result = true
    var hold = false
    var played: [TTSClip] = []
    var stops = 0
    private var waiting: CheckedContinuation<Bool, Never>?

    func play(_ clip: TTSClip) async -> Bool {
        played.append(clip)
        guard hold else { return result }
        return await withCheckedContinuation { waiting = $0 }
    }

    func stop() {
        stops += 1
        release(true)
    }

    func release(_ value: Bool) {
        waiting?.resume(returning: value)
        waiting = nil
    }
}

@MainActor
private final class FakeSpeaker: ReadAloudLocalSpeaking {
    var hold = false
    var spoken: [(text: String, voice: String?, rate: Float)] = []
    var stops = 0
    private var waiting: CheckedContinuation<Bool, Never>?

    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        spoken.append((text, voice, rate))
        guard hold else { return true }
        return await withCheckedContinuation { waiting = $0 }
    }

    func stop() {
        stops += 1
        release()
    }

    func release() {
        waiting?.resume(returning: true)
        waiting = nil
    }
}

@MainActor
private final class Harness {
    let player = FakeClipPlayer()
    let speaker = FakeSpeaker()
    let scratch = ScratchDefaults()
    let controller: ReadAloudController
    var speakCalls: [String] = []
    var speakDelay: Duration = .zero
    var speakError: GatewayError?
    var speakReply = #"{"audioBase64":"AAEC","provider":"openai","mimeType":"audio/wav","fileExtension":"wav"}"#
    var scopes = ["operator.write"]
    var methods: Set<String>? = nil

    init(timeout: Duration = Duration.seconds(30)) {
        controller = ReadAloudController(clipPlayer: player, localSpeaker: speaker, defaults: scratch.defaults, gatewayTimeout: timeout)
        gateway = makeGateway()
    }


    var gateway: GatewayVoiceModel!

    private func makeGateway() -> GatewayVoiceModel {
        GatewayVoiceModel(methods: { [unowned self] in self.methods }, scopes: { [unowned self] in self.scopes },
                          allowsWritesWithoutAdmin: false, request: { [unowned self] method, params in
            guard method == "tts.speak" else { return [:] }
            self.speakCalls.append(params["text"]?.text ?? "")
            if self.speakDelay != .zero { try await Task.sleep(for: self.speakDelay) }
            if let error = self.speakError { throw error }
            return Fixtures.json(self.speakReply)
        })
    }
}

@MainActor
private func waitUntil(_ label: String = "", timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("Read Aloud controller")
@MainActor
struct ReadAloudControllerTests {
    @Test func gatewaySuccessPlaysClip() async {
        let h = Harness()
        h.controller.toggle(messageId: "m1", text: "Hello world.", gateway: h.gateway)
        #expect(h.controller.phase == .preparing("m1") && h.controller.isActive("m1") && h.controller.activeMessageId == "m1")
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speakCalls == ["Hello world."] && h.player.played.count == 1 && h.speaker.spoken.isEmpty)
        #expect(h.controller.lastSource == .gateway("openai"))
        #expect(h.player.played[0].fileExtension == "wav")
    }

    @Test func phaseIsSpeakingWhileClipPlays() async {
        let h = Harness()
        h.player.hold = true
        h.controller.toggle(messageId: "m1", text: "Hi.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .speaking("m1") })
        h.player.release(true)
        #expect(await waitUntil { h.controller.phase == .idle })
    }

    @Test func gatewayErrorFallsBackToDevice() async {
        let h = Harness()
        h.speakError = .rpc(code: "UNAVAILABLE", message: "TTS synthesis failed", details: nil)
        h.controller.toggle(messageId: "m1", text: "Fallback text.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speaker.spoken.map(\.text) == ["Fallback text."] && h.player.played.isEmpty)
        #expect(h.controller.lastSource == .device)
    }

    @Test func methodNotFoundFallsBackAndIsRemembered() async {
        let h = Harness()
        h.speakError = .rpc(code: "UNKNOWN_METHOD", message: "unknown method: tts.speak", details: nil)
        h.controller.toggle(messageId: "m1", text: "One.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speaker.spoken.count == 1 && h.gateway.rejectedMethods.contains("tts.speak"))
        h.controller.toggle(messageId: "m2", text: "Two.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speakCalls.count == 1, "gateway isn't asked again")
        #expect(h.speaker.spoken.map(\.text) == ["One.", "Two."])
    }

    @Test(arguments: [
        #"{"audioBase64":"AAEC","mimeType":"audio/pcm"}"#,
        #"{"audioBase64":"AAEC","outputFormat":"pcm_16000"}"#,
        #"{"audioBase64":"AAEC","outputFormat":"raw-24khz-16bit-mono-pcm"}"#,
        #"{"audioBase64":""}"#,
        #"{"audioBase64":"%%%"}"#,
        #"{"provider":"openai"}"#,
    ])
    func unusableAudioFallsBackToDevice(reply: String) async {
        let h = Harness()
        h.speakReply = reply
        h.controller.toggle(messageId: "m1", text: "Words.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.player.played.isEmpty && h.speaker.spoken.map(\.text) == ["Words."] && h.controller.lastSource == .device)
    }

    @Test func undecodableClipFallsBackToDevice() async {
        let h = Harness()
        h.player.result = false
        h.controller.toggle(messageId: "m1", text: "Words.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.player.played.count == 1 && h.speaker.spoken.map(\.text) == ["Words."] && h.controller.lastSource == .device)
    }

    @Test func gatewayTimeoutFallsBackToDevice() async {
        let h = Harness(timeout: .milliseconds(50))
        h.speakDelay = .seconds(300)
        h.controller.toggle(messageId: "m1", text: "Slow.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speaker.spoken.map(\.text) == ["Slow."] && h.player.played.isEmpty)
    }

    @Test func deviceSourceSkipsGateway() async {
        let h = Harness()
        h.scratch.defaults.set("device", forKey: "pincer.readAloud.source")
        h.controller.toggle(messageId: "m1", text: "Local only.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speakCalls.isEmpty && h.speaker.spoken.map(\.text) == ["Local only."] && h.controller.lastSource == .device)
    }

    @Test func gatewayIsSkippedWhenItCannotSpeak() async {
        let noWrite = Harness()
        noWrite.scopes = ["operator.read"]
        noWrite.controller.toggle(messageId: "m1", text: "A.", gateway: noWrite.gateway)
        #expect(await waitUntil { noWrite.controller.phase == .idle })
        #expect(noWrite.speakCalls.isEmpty && noWrite.speaker.spoken.count == 1)

        let unadvertised = Harness()
        unadvertised.methods = ["tts.status"]
        unadvertised.controller.toggle(messageId: "m1", text: "B.", gateway: unadvertised.gateway)
        #expect(await waitUntil { unadvertised.controller.phase == .idle })
        #expect(unadvertised.speakCalls.isEmpty && unadvertised.speaker.spoken.count == 1)

        let none = Harness()
        none.controller.toggle(messageId: "m1", text: "C.", gateway: nil)
        #expect(await waitUntil { none.controller.phase == .idle })
        #expect(none.speaker.spoken.count == 1)
    }

    @Test func deviceVoiceAndRateComeFromSettings() async {
        let h = Harness()
        h.scratch.defaults.set("device", forKey: "pincer.readAloud.source")
        h.scratch.defaults.set("com.apple.voice.compact.en-US.Samantha", forKey: "pincer.readAloud.deviceVoice")
        h.scratch.defaults.set(0.6, forKey: "pincer.readAloud.rate")
        h.controller.toggle(messageId: "m1", text: "Hi.", gateway: nil)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speaker.spoken[0].voice == "com.apple.voice.compact.en-US.Samantha" && h.speaker.spoken[0].rate == 0.6)

        let defaults = Harness()
        defaults.controller.toggle(messageId: "m1", text: "Hi.", gateway: nil)
        #expect(await waitUntil { defaults.controller.phase == .idle })
        #expect(defaults.speaker.spoken[0].voice == nil && defaults.speaker.spoken[0].rate == AVSpeechUtteranceDefaultSpeechRate)

        let clamped = Harness()
        clamped.scratch.defaults.set(5.0, forKey: "pincer.readAloud.rate")
        clamped.controller.toggle(messageId: "m1", text: "Hi.", gateway: nil)
        #expect(await waitUntil { clamped.controller.phase == .idle })
        #expect(clamped.speaker.spoken[0].rate == 0.7)
    }

    @Test func gatewayTextIsTruncatedButDeviceGetsFullText() async {
        let long = String(repeating: "This is a sentence. ", count: 400)
        let h = Harness()
        h.controller.toggle(messageId: "m1", text: long, gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        #expect(h.speakCalls.count == 1 && h.speakCalls[0].count <= 4000 && h.speakCalls[0].count > 3000)

        let device = Harness()
        device.speakError = .rpc(code: "UNAVAILABLE", message: "x", details: nil)
        device.controller.toggle(messageId: "m1", text: long, gateway: device.gateway)
        #expect(await waitUntil { device.controller.phase == .idle })
        #expect(device.speaker.spoken[0].text.count == long.trimmingCharacters(in: .whitespaces).count)
    }

    @Test func toggleOnActiveMessageStops() async {
        let h = Harness()
        h.player.hold = true
        h.controller.toggle(messageId: "m1", text: "Hello.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .speaking("m1") })
        h.controller.toggle(messageId: "m1", text: "Hello.", gateway: h.gateway)
        #expect(h.controller.phase == .idle && h.controller.activeMessageId == nil && h.player.stops > 0)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .idle && h.speaker.spoken.isEmpty, "stopping doesn't fall back to the device voice")
    }

    @Test func stopWhilePreparingCancelsGatewayRequest() async {
        let h = Harness()
        h.speakDelay = .milliseconds(100)
        h.controller.toggle(messageId: "m1", text: "Hello.", gateway: h.gateway)
        #expect(h.controller.phase == .preparing("m1"))
        h.controller.stop()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.controller.phase == .idle && h.player.played.isEmpty && h.speaker.spoken.isEmpty)
    }

    @Test func newMessageSupersedesOldOne() async {
        let h = Harness()
        h.player.hold = true
        h.controller.toggle(messageId: "m1", text: "First.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .speaking("m1") })
        h.controller.toggle(messageId: "m2", text: "Second.", gateway: h.gateway)
        #expect(h.controller.activeMessageId == "m2")
        #expect(await waitUntil { h.controller.phase == .speaking("m2") })
        // The superseded playback finishing must not clear the newer phase.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .speaking("m2") && h.player.played.count == 2)
        #expect(h.speaker.spoken.isEmpty, "a superseded playback doesn't fall back")
        h.player.release(true)
        #expect(await waitUntil { h.controller.phase == .idle })
    }

    @Test func supersededDeviceSpeechDoesNotClearNewPhase() async {
        let h = Harness()
        h.scratch.defaults.set("device", forKey: "pincer.readAloud.source")
        h.speaker.hold = true
        h.controller.toggle(messageId: "m1", text: "First.", gateway: nil)
        #expect(await waitUntil { h.controller.phase == .speaking("m1") })
        h.controller.toggle(messageId: "m2", text: "Second.", gateway: nil)
        #expect(await waitUntil { h.controller.phase == .speaking("m2") && h.speaker.spoken.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .speaking("m2"))
        h.speaker.release()
        #expect(await waitUntil { h.controller.phase == .idle })
    }

    @Test func emptyTextIsIgnored() async {
        let h = Harness()
        h.controller.toggle(messageId: "m1", text: "  \n ", gateway: h.gateway)
        #expect(h.controller.phase == .idle && h.speakCalls.isEmpty)
    }

    @Test func staleGatewayReplyAfterSupersedeIsDropped() async {
        let h = Harness()
        h.speakDelay = .milliseconds(80)
        h.controller.toggle(messageId: "m1", text: "Slow gateway.", gateway: h.gateway)
        h.scratch.defaults.set("device", forKey: "pincer.readAloud.source")
        h.controller.toggle(messageId: "m2", text: "Fast device.", gateway: h.gateway)
        #expect(await waitUntil { h.controller.phase == .idle })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.player.played.isEmpty, "the first message's clip never plays")
        #expect(h.speaker.spoken.map(\.text) == ["Fast device."])
    }
}
