import AVFoundation
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Actual voice preview completion ownership", .serialized)
struct VoicePreviewCompletionOwnershipTests {
    private func silentFile() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-silent-preview-\(UUID().uuidString).wav")
            let length: UInt32 = 8000 * 2 * 60
            var data = Data()
            func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
            func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            ascii("RIFF"); u32(36 + length); ascii("WAVEfmt "); u32(16)
            u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            ascii("data"); u32(length); data.append(Data(count: Int(length)))
            try data.write(to: url)
            return url
        }.value
    }
    private func drainQueuedMainWork() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        for _ in 0..<8 { await Task.yield() }
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func oldActualPreviewCompletionCannotStopReplacement(_ aba: Bool) async throws {
        let url = try await silentFile()
        defer { Task.detached { try? FileManager.default.removeItem(at: url) } }
        let setup = VoiceSetupController()
        defer { setup.stop() }
        let a = ElevenLabsVoice(id: "silent-A", name: "Silent A", previewURL: url)
        let b = ElevenLabsVoice(id: "silent-B", name: "Silent B", previewURL: url)
        setup.playPreview(a)
        let oldItem = try #require(setup.currentPreviewItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        setup.playPreview(b)
        if aba { setup.playPreview(a) }
        let replacement = try #require(setup.currentPreviewItem)
        #expect(replacement !== oldItem)
        let expected = aba ? a.id : b.id
        try #require(setup.playingId == expected)
        await drainQueuedMainWork()
        #expect(setup.playingId == expected && setup.currentPreviewItem === replacement,
                "An already delivered old AVPlayerItem completion must not stop newer playback, including same-ID replacement")
    }
    @Test(.timeLimit(.minutes(2)))
    func actualCurrentCompletionAndExplicitStopStillStopPlayback() async throws {
        let url = try await silentFile()
        defer { Task.detached { try? FileManager.default.removeItem(at: url) } }
        let setup = VoiceSetupController()
        defer { setup.stop() }
        let voice = ElevenLabsVoice(id: "silent-control", name: "Silent control", previewURL: url)
        setup.playPreview(voice)
        let item = try #require(setup.currentPreviewItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try #require(await eventually { setup.playingId == nil && setup.currentPreviewItem == nil },
                     "The actual current item's completion still stops playback")
        setup.playPreview(voice)
        try #require(setup.playingId == voice.id && setup.currentPreviewItem != nil)
        setup.stop()
        #expect(setup.playingId == nil && setup.currentPreviewItem == nil)
    }
}
#if os(iOS)
@MainActor
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func actualVoicePreviewCompletionOwnsItsPlayback(_ aba: Bool) async throws {
        try await VoicePreviewCompletionOwnershipTests().oldActualPreviewCompletionCannotStopReplacement(aba)
    }
    @Test(.timeLimit(.minutes(2)))
    func actualVoicePreviewCurrentEndAndExplicitStopWork() async throws {
        try await VoicePreviewCompletionOwnershipTests().actualCurrentCompletionAndExplicitStopStillStopPlayback()
    }
}
#endif
