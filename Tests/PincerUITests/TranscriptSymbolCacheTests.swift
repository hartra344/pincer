#if os(macOS)
import AppKit
import Testing
@testable import PincerUI

@MainActor
@Suite("Transcript symbol tint cache", .serialized)
struct TranscriptSymbolCacheTests {
    private func image(_ name: String = "face.smiling", size: CGFloat = 16,
                       weight: TranscriptSymbols.Weight = .regular, width: CGFloat = 16,
                       color: NSColor = .systemRed) throws -> NSImage {
        try #require(TranscriptSymbols.tintedImage(name, size: size, weight: weight,
                                                   drawnSize: CGSize(width: width, height: 16), color: color))
    }

    @Test func symbolSizeWeightColorAndDrawnBoundsCannotShareTheWrongImage() throws {
        let original = try self.image()
        #expect(try self.image("doc") !== original)
        #expect(try self.image(size: 17) !== original)
        #expect(try self.image(weight: .bold) !== original)
        #expect(try self.image(width: 15) !== original)
        #expect(try self.image(color: .systemBlue) !== original)
        #expect(try self.image() === original)
    }

    @Test func appearanceChangesInvalidateImagesAndResolveDynamicColors() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        var first: NSImage?
        var same: NSImage?
        var changed: NSImage?
        var restored: NSImage?
        light.performAsCurrentDrawingAppearance {
            first = TranscriptSymbols.tintedImage("face.smiling", size: 16, drawnSize: CGSize(width: 16, height: 16), color: .labelColor)
            same = TranscriptSymbols.tintedImage("face.smiling", size: 16, drawnSize: CGSize(width: 16, height: 16), color: .labelColor)
        }
        dark.performAsCurrentDrawingAppearance {
            changed = TranscriptSymbols.tintedImage("face.smiling", size: 16, drawnSize: CGSize(width: 16, height: 16), color: .labelColor)
        }
        light.performAsCurrentDrawingAppearance {
            restored = TranscriptSymbols.tintedImage("face.smiling", size: 16, drawnSize: CGSize(width: 16, height: 16), color: .labelColor)
        }
        #expect(first != nil && first === same)
        #expect(changed != nil && changed !== first)
        #expect(restored != nil && restored !== first)
    }

    @Test func repeatedToolSymbolDrawsReuseTheTintedImage() throws {
        let first = try #require(TranscriptSymbols.tintedImage("face.smiling", size: 16,
                                                             drawnSize: CGSize(width: 16, height: 16), color: .systemRed))
        let second = try #require(TranscriptSymbols.tintedImage("face.smiling", size: 16,
                                                              drawnSize: CGSize(width: 16, height: 16), color: .systemRed))
        #expect(first === second, "streaming redraws must reuse the same tinted symbol image")
    }
}
#endif
