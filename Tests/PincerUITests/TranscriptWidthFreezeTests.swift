import CoreGraphics
import Testing
@testable import PincerUI

@Suite("TranscriptWidthFreeze")
struct TranscriptWidthFreezeTests {
    @Test func startsThawed() {
        let freeze = TranscriptWidthFreeze()
        #expect(!freeze.isFrozen)
        #expect(freeze.frozenWidth == nil)
        #expect(freeze.isQuiet(at: 0))
        #expect(freeze.remainingQuiet(at: 0) == 0)
    }

    @Test func firstChangeFreezesAtOldWidth() {
        var freeze = TranscriptWidthFreeze()
        let r1 = freeze.widthChanged(from: 900, to: 880, at: 1)
        #expect(r1)
        #expect(freeze.isFrozen)
        #expect(freeze.frozenWidth == 900)
    }

    @Test func laterChangesKeepOriginalWidthAndExtendQuiet() {
        var freeze = TranscriptWidthFreeze()
        freeze.widthChanged(from: 900, to: 880, at: 1.00)
        let r2 = freeze.widthChanged(from: 880, to: 860, at: 1.05)
        #expect(r2)
        #expect(freeze.frozenWidth == 900)
        #expect(!freeze.isQuiet(at: 1.10))
        #expect(freeze.isQuiet(at: 1.05 + TranscriptWidthFreeze.quietInterval))
    }

    @Test func remainingQuietCountsDownFromLastChange() {
        var freeze = TranscriptWidthFreeze()
        freeze.widthChanged(from: 900, to: 880, at: 2)
        #expect(abs(freeze.remainingQuiet(at: 2.03) - 0.07) < 1e-9)
        #expect(freeze.remainingQuiet(at: 2.5) == 0)
        freeze.widthChanged(from: 880, to: 860, at: 2.08)
        #expect(abs(freeze.remainingQuiet(at: 2.10) - 0.08) < 1e-9)
    }

    @Test func thawReturnsWidthAndUnfreezes() {
        var freeze = TranscriptWidthFreeze()
        freeze.widthChanged(from: 900, to: 640, at: 1)
        let frozen = freeze.thaw()
        #expect(frozen == 900)
        #expect(!freeze.isFrozen)
        #expect(freeze.isQuiet(at: 1))
        let again = freeze.thaw()
        #expect(again == nil)
    }

    @Test func unchangedWidthIsNoOp() {
        var freeze = TranscriptWidthFreeze()
        let r3 = freeze.widthChanged(from: 900, to: 900, at: 1)
        #expect(!r3)
        #expect(!freeze.isFrozen)
        freeze.widthChanged(from: 900, to: 880, at: 1)
        let r4 = freeze.widthChanged(from: 880, to: 880, at: 1.05)
        #expect(!r4)
        #expect(abs(freeze.remainingQuiet(at: 1.05) - 0.05) < 1e-9)
    }

    @Test func refreezesAfterThaw() {
        var freeze = TranscriptWidthFreeze()
        freeze.widthChanged(from: 900, to: 640, at: 1)
        freeze.thaw()
        freeze.widthChanged(from: 640, to: 900, at: 2)
        #expect(freeze.frozenWidth == 640)
    }
}
