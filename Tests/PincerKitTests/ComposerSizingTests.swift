import CoreGraphics
import Testing
@testable import PincerKit

@Suite("Composer sizing policy")
struct ComposerSizingTests {
    @Test func capThresholdBoundary() {
        #expect(ComposerSizing.cappedEstimateThreshold == 20000)
        #expect(!ComposerSizing.usesCappedEstimate(utf16Count: 0))
        #expect(!ComposerSizing.usesCappedEstimate(utf16Count: 20000))
        #expect(ComposerSizing.usesCappedEstimate(utf16Count: 20001))
    }

    @Test func capScalesWithLinesAndRoundsUp() {
        #expect(ComposerSizing.cap(lineHeight: 16, maxLines: 12) == 192)
        #expect(ComposerSizing.cap(lineHeight: 15.4, maxLines: 12) == 185)
        #expect(ComposerSizing.cap(lineHeight: 16, maxLines: 1) == 16)
        #expect(ComposerSizing.cap(lineHeight: 16, maxLines: 0) == 16)
        #expect(ComposerSizing.cap(lineHeight: 16, maxLines: -3) == 16)
    }

    @Test func clampedHeightBounds() {
        #expect(ComposerSizing.clampedHeight(0, lineHeight: 16, maxLines: 12) == 16)
        #expect(ComposerSizing.clampedHeight(10, lineHeight: 16, maxLines: 12) == 16)
        #expect(ComposerSizing.clampedHeight(48, lineHeight: 16, maxLines: 12) == 48)
        #expect(ComposerSizing.clampedHeight(48.2, lineHeight: 16, maxLines: 12) == 49)
        #expect(ComposerSizing.clampedHeight(10_000, lineHeight: 16, maxLines: 12) == 192)
        #expect(ComposerSizing.clampedHeight(100, lineHeight: 16, maxLines: 1) == 16)
        #expect(ComposerSizing.clampedHeight(100, lineHeight: 16, maxLines: 0) == 16)
    }

    @Test func nonFiniteMeasurementFallsBackToOneLine() {
        #expect(ComposerSizing.clampedHeight(.nan, lineHeight: 16, maxLines: 12) == 16)
        #expect(ComposerSizing.clampedHeight(.infinity, lineHeight: 16, maxLines: 12) == 16)
        #expect(ComposerSizing.clampedHeight(-.infinity, lineHeight: 16, maxLines: 12) == 16)
    }
}
