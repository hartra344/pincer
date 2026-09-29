import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite("Streaming rendering", .serialized)
struct StreamingRenderingTests {
    static func reply(seed: Int = 1, paragraphs: Int) -> String {
        let sentence = "Streaming words with **bold**, `code` and a [link](https://example.com) to parse. "
        var out = ""
        for n in 0..<paragraphs {
            switch (n + seed) % 6 {
            case 0: out += "## Heading \(n)\n\n\(sentence)\(sentence)\n\n"
            case 1: out += (1...3).map { "- bullet \($0) \(sentence)" }.joined(separator: "\n") + "\n\n"
            case 2: out += (1...3).map { "\($0). step \($0) \(sentence)" }.joined(separator: "\n") + "\n\n"
            case 3: out += "```swift\nlet a = \(n)\n\nlet b = 2\n```\n\n"
            case 4: out += "> quoted \(sentence)\n\n"
            default: out += sentence + sentence + "\n\n"
            }
        }
        return out
    }

    /// Text runs joined the way a single committed view lays them out, other segments as markers.
    static func flatten(_ segments: [TranscriptText.Segment]) -> [String] {
        var result: [String] = []
        for segment in segments {
            switch segment {
            case let .text(text): result.append("T:" + text.string)
            case let .quote(text): result.append("Q:" + text.string)
            case let .code(language, code, _): result.append("C:\(language):\(code)")
            case let .table(table): result.append("TB:" + table.plainText)
            case .rule: result.append("R")
            }
        }
        return result
    }

    /// Merges adjacent text runs, which the live split may separate into frozen views.
    static func merged(_ parts: [String]) -> [String] {
        var out: [String] = []
        for part in parts {
            if part.hasPrefix("T:"), let last = out.last, last.hasPrefix("T:") {
                out[out.count - 1] = last + "\n" + part.dropFirst(2)
            } else {
                out.append(part)
            }
        }
        return out
    }

    @Test func lruCacheNeverExceedsCapacityAndEvictsOldest() {
        var cache = LRUCache<Int, Int>(capacity: 5)
        for i in 0..<100 { cache.set(i, for: i); #expect(cache.count <= 5) }
        #expect(cache.count == 5)
        #expect(cache.value(for: 99) == 99)
        #expect(cache.value(for: 0) == nil)
        // Touching an entry keeps it through further churn.
        _ = cache.value(for: 95)
        for i in 200..<203 { cache.set(i, for: i) }
        #expect(cache.value(for: 95) == 95)
        #expect(cache.value(for: 96) == nil)
        cache.set(-1, for: 95)
        #expect(cache.count == 5 && cache.value(for: 95) == -1)
        cache.removeAll()
        #expect(cache.count == 0)
        cache.set(1, for: 1)
        #expect(cache.count == 1)
    }

    @Test func sharedCachesStayBounded() {
        for i in 0..<(MarkdownCache.blockCapacity + 200) { _ = MarkdownCache.blocks("paragraph number \(i)") }
        #expect(MarkdownCache.counts.blocks <= MarkdownCache.blockCapacity)
        for i in 0..<(TranscriptText.segmentCapacity + 100) { _ = TranscriptText.markdown("message \(i)", tone: .primary) }
        #expect(TranscriptText.segmentCacheCount <= TranscriptText.segmentCapacity)
    }

    @Test func streamingLongReplyLeavesSharedCachesFlat() {
        // Warm state, so any leak from streaming would show as growth.
        _ = TranscriptText.markdown("warm", tone: .primary)
        let text = Self.reply(paragraphs: 200)
        #expect(text.utf8.count > 25_000)
        let before = (MarkdownCache.counts, TranscriptText.segmentCacheCount)
        var end = text.startIndex
        while end < text.endIndex {
            end = text.index(end, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            _ = TranscriptText.liveMarkdown(String(text[..<end]), tone: .primary, row: "live-run_flat")
        }
        let after = (MarkdownCache.counts, TranscriptText.segmentCacheCount)
        #expect(after.0.blocks == before.0.blocks && after.0.inlines == before.0.inlines)
        #expect(after.1 == before.1)
        let memo = TranscriptText.liveMemoCount
        #expect(memo.chunks > 0)
        TranscriptText.endLive(row: "live-run_flat")
        #expect(TranscriptText.liveMemoCount.rows == memo.rows - 1)
    }

    @Test func liveSegmentsMatchCommittedText() {
        let text = Self.reply(paragraphs: 60)
        var end = text.startIndex
        while end < text.endIndex {
            end = text.index(end, offsetBy: 997, limitedBy: text.endIndex) ?? text.endIndex
            let prefix = String(text[..<end])
            let live = TranscriptText.liveMarkdown(prefix, tone: .primary, row: "live-run_eq").map(\.segment)
            let committed = TranscriptText.markdown(prefix, tone: .primary)
            #expect(Self.merged(Self.flatten(live)) == Self.merged(Self.flatten(committed)), "prefix \(prefix.count)")
        }
        TranscriptText.endLive(row: "live-run_eq")
    }

    @Test func frozenSegmentIdentityIsStableAcrossFlushes() {
        let text = Self.reply(paragraphs: 40)
        let half = String(text.prefix(text.count * 2 / 3))
        let a = TranscriptText.liveMarkdown(half, tone: .primary, row: "live-run_id")
        let b = TranscriptText.liveMarkdown(half + "more words appended", tone: .primary, row: "live-run_id")
        let frozenA = a.filter(\.isFrozen), frozenB = b.filter(\.isFrozen)
        #expect(!frozenA.isEmpty)
        for (x, y) in zip(frozenA, frozenB) {
            if case let .text(p) = x.segment, case let .text(q) = y.segment { #expect(p === q) }
        }
        TranscriptText.endLive(row: "live-run_id")
    }

    // MARK: Row layout

    func renderer() -> (TranscriptRenderer, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:t:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        return (TranscriptRenderer(context: context), scratch)
    }

    static func texts(_ layout: TranscriptRowLayout) -> [String] {
        layout.parts.compactMap { placed in
            switch placed.part {
            case let .text(t): "T:" + t.string
            case let .code(code): "C:" + code.code
            default: nil
            }
        }
    }

    @Test func liveRowLayoutMatchesCommittedRow() {
        let (renderer, scratch) = self.renderer()
        defer { scratch.remove() }
        let text = Self.reply(paragraphs: 40)
        func heights(_ body: String, _ width: CGFloat) -> (CGFloat, committed: CGFloat, TranscriptRowLayout, TranscriptRowLayout) {
            var live = AssistantTurn(id: "live-run_layout", timestamp: Date(timeIntervalSince1970: 1))
            live.text = [body]
            live.isStreaming = true
            var done = AssistantTurn(id: "done-run_layout", timestamp: Date(timeIntervalSince1970: 1))
            done.text = [body]
            let l = renderer.layout(for: .entry(.assistant(live)), width: width)
            let d = renderer.layout(for: .entry(.assistant(done)), width: width)
            return (l.height, d.height, l, d)
        }
        for width in [420.0, 700.0] {
            // Committed rows add a footer that live rows don't have; everything else must line up.
            let probe = heights("Hi", width)
            let footer = probe.committed - probe.0
            for fraction in [0.3, 0.7, 1.0] {
                let prefix = String(text.prefix(Int(Double(text.count) * fraction)))
                let h = heights(prefix, width)
                let liveLayout = h.2, doneLayout = h.3
                #expect(abs(h.committed - h.0 - footer) <= 1,
                        "w \(width) f \(fraction): live \(h.0) vs committed \(h.committed) (footer \(footer))")
                let liveText = Self.merged(Self.texts(liveLayout)).joined(separator: "|")
                let doneText = Self.merged(Self.texts(doneLayout)).joined(separator: "|")
                #expect(liveText == doneText, "w \(width) f \(fraction)")
            }
        }
    }

    @Test func liveMemoHoldsSeveralRowsAndDropsTheLeastRecentlyUsed() {
        let text = Self.reply(paragraphs: 30)
        let ids = (0..<6).map { "live-run_multi\($0)" }
        for id in ids { TranscriptText.endLive(row: id) }
        let base = TranscriptText.liveMemoCount.rows
        // Two rows streaming alternately keep their chunks (identity stays stable, nothing thrashes).
        var firsts: [[TranscriptText.LiveSegment]] = []
        for id in ids.prefix(2) { firsts.append(TranscriptText.liveMarkdown(text, tone: .primary, row: id)) }
        for (n, id) in ids.prefix(2).enumerated() {
            let again = TranscriptText.liveMarkdown(text + "x", tone: .primary, row: id)
            for (x, y) in zip(firsts[n].filter(\.isFrozen), again.filter(\.isFrozen)) {
                if case let .text(p) = x.segment, case let .text(q) = y.segment { #expect(p === q) }
            }
        }
        #expect(TranscriptText.liveMemoCount.rows == base + 2)
        for id in ids { _ = TranscriptText.liveMarkdown(text, tone: .primary, row: id) }
        #expect(TranscriptText.liveMemoCount.rows <= TranscriptText.liveRowCapacity)
        for id in ids { TranscriptText.endLive(row: id) }
    }

    @Test func liveMemoIsFreedWhenTheChatStopsStreaming() {
        let (renderer, scratch) = self.renderer()
        defer { scratch.remove() }
        let before = TranscriptText.liveMemoCount.rows
        var live = AssistantTurn(id: "live-run_free", timestamp: Date(timeIntervalSince1970: 1))
        live.text = [Self.reply(paragraphs: 20)]
        live.isStreaming = true
        _ = renderer.layout(for: .entry(.assistant(live)), width: 600)
        #expect(TranscriptText.liveMemoCount.rows == before + 1)
        var done = AssistantTurn(id: "msg-committed", timestamp: Date(timeIntervalSince1970: 1))
        done.text = live.text
        _ = renderer.layout(for: .entry(.assistant(done)), width: 600)
        #expect(TranscriptText.liveMemoCount.rows == before)
    }
}
