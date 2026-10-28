import Foundation
import Testing
#if os(macOS)
import AppKit
@testable import PincerUI
#endif

@Suite("Shared appearance turn")
struct SharedAppearanceTurnTests {
    @Test func writerWaitsForReadersAndBlocksLaterReaders() async {
        let turn = SharedAppearanceTurn()
        await turn.acquire(exclusive: false)
        await turn.acquire(exclusive: false)
        let writer = Task { await turn.acquire(exclusive: true) }
        await Self.settle()
        let reader = Task { await turn.acquire(exclusive: false) }
        await Self.settle()
        #expect(await turn.state == .init(readers: 2, writing: false), "the writer waits while readers hold the turn")

        await turn.release(exclusive: false)
        await turn.release(exclusive: false)
        await writer.value
        #expect(await turn.state == .init(readers: 0, writing: true), "the writer goes before the reader that queued after it")

        await turn.release(exclusive: true)
        await reader.value
        #expect(await turn.state == .init(readers: 1, writing: false))
        await turn.release(exclusive: false)
        #expect(await turn.state == .init(readers: 0, writing: false))
    }

    @Test func readersShareTheTurn() async {
        let turn = SharedAppearanceTurn()
        await turn.acquire(exclusive: false)
        await turn.acquire(exclusive: false)
        #expect(await turn.state == .init(readers: 2, writing: false))
        await turn.release(exclusive: false)
        await turn.release(exclusive: false)
        await turn.acquire(exclusive: true)
        #expect(await turn.state == .init(readers: 0, writing: true))
        await turn.release(exclusive: true)
    }

    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

#if os(macOS)
/// Why the probes need the turn: a theme change made by another test (here the accent write
/// `CodeHeaderAppearanceTests` makes) rebuilds the rows of a live transcript in the middle of a frozen
/// panel slide. On CI that was `PanelSlideProbe` counting 12 layout builds in its frames.
@MainActor
@Suite("Shared appearance reaches live transcripts", .serialized, .changesSharedAppearance)
struct SharedAppearanceInterferenceTests {
    @Test func themeChangeRebuildsALiveTranscriptMidSlide() async {
        let host = await PanelSlideProbe.makeHost(rows: TranscriptPrefetchProbe.rows(count: 400))
        await PanelSlideProbe.waitQuiet(host)
        let defaults = UserDefaults.standard
        let key = ThemeRole.accent.storageKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            AppTheme.invalidateCache()
        }

        PanelSlideProbe.setWidth(host, PanelSlideProbe.wide - 20)
        #expect(host.coordinator.isWidthFrozen, "the slide freezes the width")
        let before = PanelSlideProbe.builds(host)
        defaults.set(AppTheme.current.value(.accent) == ThemeColor(hex: "CC3300") ? "008844" : "CC3300", forKey: key)
        AppTheme.invalidateCache()
        #expect(host.coordinator.isWidthFrozen)
        #expect(PanelSlideProbe.builds(host) > before, "the theme change rebuilt visible rows during the slide")
    }
}
#endif
