#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #1067: live Markdown styling of the composer's text storage, and its per-keystroke cost.
@MainActor
@Suite("Composer Markdown styler")
struct ComposerMarkdownStylerTests {
    static func makeStyler() -> ComposerMarkdownStyler {
        ComposerMarkdownStyler()
    }

    static func font(_ storage: NSTextStorage, at location: Int) -> NSFont? {
        storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    static func color(_ storage: NSTextStorage, at location: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    static func restyleAll(_ styler: ComposerMarkdownStyler, _ storage: NSTextStorage) {
        _ = styler.restyle(storage, editedRange: NSRange(location: 0, length: storage.length), changeInLength: storage.length)
    }

    @Test func appliesFontsAndDimmedMarkers() {
        let styler = Self.makeStyler()
        let storage = NSTextStorage(string: "x **bold** _it_ `mono` y")
        Self.restyleAll(styler, storage)
        let ns = storage.string as NSString
        let bold = ns.range(of: "bold").location
        let italic = ns.range(of: "it").location
        let mono = ns.range(of: "mono").location
        #expect(Self.font(storage, at: bold)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(Self.font(storage, at: italic)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(Self.font(storage, at: mono)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(Self.font(storage, at: 0)?.fontDescriptor.symbolicTraits.contains(.bold) != true)
        let markerColor = Self.color(storage, at: ns.range(of: "**").location)
        let bodyColor = Self.color(storage, at: 0)
        #expect(markerColor != nil && markerColor != bodyColor)
        #expect(Self.color(storage, at: bold) == bodyColor)
    }

    @Test func headingsAreBoldAtBodySize() {
        let styler = Self.makeStyler()
        let storage = NSTextStorage(string: "plain\n## Title")
        Self.restyleAll(styler, storage)
        let title = (storage.string as NSString).range(of: "Title").location
        #expect(Self.font(storage, at: title)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(Self.font(storage, at: title)?.pointSize == Self.font(storage, at: 0)?.pointSize)
    }

    @Test func restyleClearsStaleStyling() {
        let styler = Self.makeStyler()
        let storage = NSTextStorage(string: "**bold**")
        Self.restyleAll(styler, storage)
        storage.replaceCharacters(in: NSRange(location: 6, length: 2), with: "")
        _ = styler.restyle(storage, editedRange: NSRange(location: 6, length: 0), changeInLength: -2)
        #expect(Self.font(storage, at: 3)?.fontDescriptor.symbolicTraits.contains(.bold) != true)
    }

    @Test func typingRestylesOnlyTheParagraph() {
        let styler = Self.makeStyler()
        let storage = NSTextStorage(string: "first **a**\nsecond line\nthird")
        Self.restyleAll(styler, storage)
        storage.replaceCharacters(in: NSRange(location: 15, length: 0), with: "x")
        let range = styler.restyle(storage, editedRange: NSRange(location: 15, length: 1), changeInLength: 1)
        #expect(NSLocationInRange(15, range))
        #expect(range.length <= "second xline\n".utf16.count)
    }

    @Test func typingLatencyProbe() {
        let block = "# Heading\nSome **bold** and _italic_ text with `code` and [a link](https://example.com/x) 😀 你好\n- item one\n> quote ~~gone~~\n```\nlet x = 1 // **raw**\n```\n\n"
        var draft = ""
        while (draft as NSString).length < 20_000 { draft += block }
        let styler = Self.makeStyler()
        let storage = NSTextStorage(string: draft)
        Self.restyleAll(styler, storage)

        var rng = StylerProbeRandom(seed: 20_000)
        var costs: [Duration] = []
        var widest = 0
        for _ in 0..<200 {
            let probe = Int(rng.next() % UInt64(storage.length - 1))
            let para = ComposerMarkdown.paragraphRange(in: storage.string as NSString, covering: NSRange(location: probe, length: 0))
            if (storage.string as NSString).substring(with: para).hasPrefix("```") { continue }
            let location = para.location + min(1, para.length)
            storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "x")
            let start = ContinuousClock.now
            let range = styler.restyle(storage, editedRange: NSRange(location: location, length: 1), changeInLength: 1)
            costs.append(ContinuousClock.now - start)
            widest = max(widest, range.length)
        }
        costs.sort()
        let p95 = costs[Int(Double(costs.count - 1) * 0.95)]
        print("composer markdown restyle: p95 \(p95), max \(costs.last!), widest range \(widest) UTF-16")
        #expect(widest < 500, "a keystroke restyled \(widest) UTF-16 units")
        #expect(p95 < PerfBudget.limit(.milliseconds(2)), "p95 restyle took \(p95)")
    }
}
#endif

private struct StylerProbeRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
