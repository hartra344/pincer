#if os(macOS)
import AppKit
import Testing
@testable import PincerUI

@MainActor
@Suite("Transcript symbol tint cache", .serialized)
struct TranscriptSymbolCacheTests {
    @Test func repeatedToolSymbolDrawsReuseTheTintedImage() throws {
        let first = try #require(TranscriptSymbols.tintedImage("face.smiling", size: 16,
                                                             drawnSize: CGSize(width: 16, height: 16), color: .systemRed))
        let second = try #require(TranscriptSymbols.tintedImage("face.smiling", size: 16,
                                                              drawnSize: CGSize(width: 16, height: 16), color: .systemRed))
        #expect(first === second, "streaming redraws must reuse the same tinted symbol image")
    }
}
#endif
