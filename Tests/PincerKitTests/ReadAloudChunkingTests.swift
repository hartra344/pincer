import Foundation
import Testing
@testable import PincerKit

/// Plays each clip until the test releases it, so fetches during playback are observable.
@MainActor
private final class HeldClips: ReadAloudClipPlaying {
    var played: [String] = []
    private var waiting: CheckedContinuation<Bool, Never>?
    var isPlaying: Bool { self.waiting != nil }

    func play(_ clip: TTSClip) async -> Bool {
        self.played.append(clip.provider ?? "")
        return await withCheckedContinuation { self.waiting = $0 }
    }

    func finish() { self.waiting?.resume(returning: true); self.waiting = nil }
    func stop() { self.finish() }
}

@MainActor
private final class Device: ReadAloudLocalSpeaking {
    var spoken: [String] = []
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool { self.spoken.append(text); return true }
    func stop() {}
}

@MainActor
private func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

private let paragraphs = (1 ... 3).map { p in (1 ... 12).map { "Paragraph \(p) sentence \($0) is here." }.joined(separator: " ") }
private let message = "Opening line.\n\n" + paragraphs.joined(separator: "\n\n")

@Suite("Read Aloud chunked Gateway voice")
@MainActor
struct ReadAloudChunkingTests {
    private func setup(fail: Set<Int> = [], hang: Set<Int> = [], timeout: Duration = .seconds(30))
        -> (ReadAloudController, HeldClips, Device, GatewayVoiceModel, () -> [String])
    {
        let scratch = ScratchDefaults()
        let clips = HeldClips()
        let device = Device()
        let controller = ReadAloudController(clipPlayer: clips, localSpeaker: device, defaults: scratch.defaults, gatewayTimeout: timeout)
        var requested: [String] = []
        let gateway = GatewayVoiceModel(methods: { nil }, scopes: { ["operator.write"] }, request: { method, params in
            guard method == "tts.speak" else { return [:] }
            let text = params["text"]?.string ?? ""
            let index = requested.count
            requested.append(text)
            if hang.contains(index) { try await Task.sleep(for: .seconds(60)) }
            if fail.contains(index) { throw GatewayError.rpc(code: "UNAVAILABLE", message: "down", details: nil) }
            return Fixtures.json("{\"audioBase64\":\"AAEC\",\"provider\":\"c\(index)\",\"mimeType\":\"audio/wav\",\"fileExtension\":\"wav\"}")
        })
        return (controller, clips, device, gateway, { requested })
    }

    @Test func chunksAreRequestedInOrderAndPrefetchedDuringPlayback() async {
        let (c, clips, device, gateway, requested) = self.setup()
        let chunks = SpeechChunker.chunks(message)
        #expect(chunks.count >= 3)
        c.toggle(messageId: "m", text: message, gateway: gateway)
        for n in 0 ..< chunks.count {
            await until { clips.played.count == n + 1 && clips.isPlaying }
            let expected = min(n + 2, chunks.count)
            await until { requested().count == expected }
            // While chunk n plays, chunk n+1 (and nothing further) has been requested.
            #expect(requested().count == expected)
            clips.finish()
        }
        await until { c.phase == .idle }
        #expect(requested() == chunks)
        #expect(clips.played == chunks.indices.map { "c\($0)" })
        #expect(device.spoken.isEmpty)
        #expect(c.lastSource == .gateway("c0"))
    }

    @Test func midSequenceFailureReadsOnlyTheRestOnDevice() async {
        let (c, clips, device, gateway, requested) = self.setup(fail: [2])
        let chunks = SpeechChunker.chunks(message)
        c.toggle(messageId: "m", text: message, gateway: gateway)
        await until { clips.isPlaying }; clips.finish()
        await until { clips.played.count == 2 && clips.isPlaying }; clips.finish()
        await until { c.phase == .idle }
        #expect(clips.played == ["c0", "c1"])
        #expect(device.spoken == [chunks[2...].joined(separator: "\n\n")])
        #expect(c.lastSource == .gateway("c0") && c.lastFallback == .other("down"))
        #expect(requested().count == 3)
    }

    @Test func midSequenceTimeoutFallsBackForTheRest() async {
        let (c, clips, device, gateway, _) = self.setup(hang: [1], timeout: .milliseconds(200))
        let chunks = SpeechChunker.chunks(message)
        c.toggle(messageId: "m", text: message, gateway: gateway)
        await until { clips.isPlaying }; clips.finish()
        await until { c.phase == .idle }
        #expect(clips.played == ["c0"])
        #expect(device.spoken == [chunks[1...].joined(separator: "\n\n")])
    }

    @Test func firstChunkFailureReadsTheWholeMessageOnDevice() async {
        let (c, clips, device, gateway, requested) = self.setup(fail: [0])
        c.toggle(messageId: "m", text: message, gateway: gateway)
        await until { c.phase == .idle && c.lastSource != nil }
        #expect(clips.played.isEmpty && requested().count == 1)
        #expect(device.spoken == [message])
        #expect(c.lastSource == .device && c.lastFallback == .other("down"))
    }

    @Test func stopCancelsTheWholeSequence() async {
        let (c, clips, device, gateway, requested) = self.setup()
        c.toggle(messageId: "m", text: message, gateway: gateway)
        await until { clips.isPlaying && requested().count == 2 }
        c.toggle(messageId: "m", text: message, gateway: gateway)
        #expect(c.phase == .idle)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(clips.played == ["c0"] && requested().count == 2 && device.spoken.isEmpty)
        #expect(c.phase == .idle)
    }
}
