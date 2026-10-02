import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit
#endif

/// Per-token main-thread cost of streaming a markdown reply: ChatStore ingest + (layout of the last row at
/// ~700pt + text-view set) per publish, amortised over the tokens it covers.
///
/// Run: `swift test --filter StreamingProbe` — the markdown table is printed to stdout.
///
/// ONE PLACE TO EDIT for a build with the coalescer: set `ProbeShim.flush` to `{ $0.flushLive() }`.
/// With `nil` (baseline) every token is treated as a publish. With a closure, a publish (flush + layout +
/// text set) fires only when simulated time (token i at i/60 s) crosses the cadence boundary, then once
/// at the end only if the last delta was not already published.
@MainActor
enum ProbeShim {
    static let flush: ((ChatStore) -> Void)? = { $0.flushLive() }
    /// Optional: shared cache entry counts, e.g. `{ "\(MarkdownCache.debugCounts)" }`. nil when absent.
    static let cacheCounts: (() -> String)? = { "\(MarkdownCache.counts.blocks)/\(MarkdownCache.counts.inlines)/\(TranscriptText.segmentCacheCount)" }
}

@MainActor
@Suite("StreamingProbe", .serialized)
struct StreamingProbe {
    static let key = "agent:probe:main"

    static func reply(bytes: Int) -> String {
        let sentence = "The quick brown fox jumps over the lazy dog while **bold** words, `inline code` and a [link](https://example.com) keep the inline parser busy. "
        var out = ""
        var n = 0
        while out.utf8.count < bytes {
            n += 1
            switch n % 5 {
            case 1: out += "## Section \(n)\n\n"; out += sentence + sentence + "\n\n"
            case 2: out += (1...4).map { "- bullet \($0): \(sentence)" }.joined(separator: "\n") + "\n\n"
            case 3: out += (1...4).map { "\($0). step \($0): \(sentence)" }.joined(separator: "\n") + "\n\n"
            case 4: out += "```swift\nfunc f\(n)(_ x: Int) -> Int {\n    let y = x * \(n)\n    return y + 1\n}\n```\n\n"
            default: out += sentence + sentence + sentence + "\n\n"
            }
        }
        return String(out.prefix(bytes))
    }

    static func assistant(_ text: String) -> JSONValue {
        ["role": "assistant", "content": .array([["type": "text", "text": .string(text)]])]
    }

    struct Result {
        var bytes: Int
        var tokens: Int
        var cadenceHz: Int
        var publishes: [Double] = []
        /// Text views re-set per publish (identity-equal parts are skipped): the deterministic measure of
        /// per-publish work, since only the growing tail should change.
        var textSets: [Int] = []
        var totalMs = 0.0
        var publishTotalMs = 0.0
        var counts: String?
        var finalText = ""
    }

    func run(bytes: Int, cadenceHz: Int = 30) -> Result {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: Self.key)
        let agent = AgentSummary(id: "probe", name: "Probe")
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(), agent: agent,
                                        sessionKey: Self.key, previewImage: { _ in }, saveFile: { _, _ in },
                                        chat: chat)
        let renderer = TranscriptRenderer(context: context)
        let width: CGFloat = 700
        #if os(macOS)
        var views: [NSTextView] = []
        var shown: [NSAttributedString?] = []
        #endif

        let text = Self.reply(bytes: bytes)
        // Live Markdown skips the shared committed-text caches. A distinct row key also keeps this
        // cadence sample independent of every earlier probe invocation.
        let runId = "run_probe_\(UUID().uuidString)"
        let chars = Array(text)
        var chunks: [String] = []
        var i = 0
        while i < chars.count { chunks.append(String(chars[i..<min(i + 20, chars.count)])); i += 20 }

        var result = Result(bytes: bytes, tokens: chunks.count, cadenceHz: cadenceHz)
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var sets = 0
        func publish() -> Double {
            sets = 0
            var elapsed = 0.0
            if let flush = ProbeShim.flush { elapsed += ms(clock.measure { flush(chat) }) }
            elapsed += ms(clock.measure {
                let rows = TranscriptRow.rows(for: chat)
                guard let last = rows.last else { return }
                let layout = renderer.layout(for: last, width: width)
                #if os(macOS)
                // Like the row view: one view per text part, identity-equal strings are a no-op.
                var index = 0
                for placed in layout.parts {
                    guard case let .text(attributed) = placed.part else { continue }
                    defer { index += 1 }
                    if index >= views.count {
                        let v = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
                        v.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                        views.append(v)
                        shown.append(nil)
                    }
                    if shown[index] === attributed { continue }
                    sets += 1
                    let v = views[index]
                    let old = shown[index]
                    shown[index] = attributed
                    if let storage = v.textStorage {
                        storage.update(to: attributed, keepingPrefix: old != nil)
                    }
                    if let container = v.textContainer { v.layoutManager?.ensureLayout(for: container) }
                }
                #endif
                _ = layout.height
            })
            return elapsed
        }

        func event(_ fields: [String: JSONValue]) {
            var payload = fields
            payload["runId"] = .string(runId)
            payload["sessionKey"] = .string(Self.key)
            chat.handleChat(.object(payload))
        }
        event(["state": "status", "phase": "starting_model"])

        var acc = ""
        var nextFrame = 1
        var pendingSincePublish = false
        for (index, chunk) in chunks.enumerated() {
            acc += chunk
            let eventCost = ms(clock.measure {
                event(["state": "delta", "deltaText": .string(chunk), "message": Self.assistant(acc)])
            })
            result.totalMs += eventCost
            let elapsedTicks = index + 1
            if ProbeShim.flush == nil || elapsedTicks * cadenceHz >= nextFrame * 60 {
                let p = publish()
                result.publishes.append(p)
                result.textSets.append(sets)
                result.publishTotalMs += p
                result.totalMs += p
                pendingSincePublish = false
                while nextFrame * 60 <= elapsedTicks * cadenceHz { nextFrame += 1 }
            } else {
                pendingSincePublish = true
            }
        }
        if ProbeShim.flush != nil, pendingSincePublish {
            let p = publish()
            result.publishes.append(p)
            result.textSets.append(sets)
            result.publishTotalMs += p
            result.totalMs += p
        }
        result.finalText = chat.live?.text ?? ""
        result.counts = ProbeShim.cacheCounts?()
        return result
    }

    static func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    /// What main paid per token: a cold (uncached) layout plus text-view set of the finished reply as one
    /// committed row. Median of several runs after a warm-up.
    func coldCommittedCost(bytes: Int) -> Double {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: Self.key)
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: Self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let renderer = TranscriptRenderer(context: context)
        #if os(macOS)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 100))
        view.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        #endif
        let base = Self.reply(bytes: bytes)
        let clock = ContinuousClock()
        var samples: [Double] = []
        for run in 0..<6 {
            // A unique first line per run defeats the shared markdown/segment caches.
            var turn = AssistantTurn(id: "cold-\(run)", timestamp: Date(timeIntervalSince1970: 1))
            turn.text = ["Run \(run) \(UUID().uuidString)\n\n" + base]
            let d = clock.measure {
                let layout = renderer.layout(for: .entry(.assistant(turn)), width: 700)
                #if os(macOS)
                for placed in layout.parts {
                    if case let .text(attributed) = placed.part {
                        view.textStorage?.setAttributedString(attributed)
                        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
                    }
                }
                #endif
            }
            if run > 0 { samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        }
        return samples.sorted()[samples.count / 2]
    }

    @Test func probe() {
        var rows: [String] = []
        var p95s: [Int: Double] = [:]
        var results: [Int: Result] = [:]
        for kb in [2, 10, 25] {
            let r = self.run(bytes: kb * 1000)
            results[kb] = r
            let worst = r.publishes.max() ?? 0
            let p95 = Self.p95(r.publishes)
            p95s[kb] = p95
            let mean = r.totalMs / Double(max(1, r.tokens))
            rows.append("| \(kb) KB | \(r.tokens) | \(String(format: "%.3f", mean)) | \(String(format: "%.2f", worst)) | \(String(format: "%.2f", p95)) | \(r.publishes.count) | \(r.textSets.max() ?? 0) | \(r.counts ?? "n/a") |")
        }
        let mode = ProbeShim.flush == nil ? "baseline (publish per token)" : "coalesced (30 Hz @ 60 tok/s)"
        let p10 = p95s[10] ?? 0, p25 = p95s[25] ?? 0
        let cold = self.coldCommittedCost(bytes: 25_000)
        let flatness = p25 / max(p10, 0.001)
        let relative = p25 / max(cold, 0.001)
        let frameMet = p25 <= 8.3
        let enforced = PerfBudget.enforcesWallClockRatios
        print("""

        StreamingProbe — \(mode)
        | size | tokens | per-token ms (mean) | worst publish ms | p95 publish ms | publishes | max text sets/publish | cache counts |
        |---|---|---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        p95 25 KB / p95 10 KB = \(String(format: "%.2f", flatness)) (limit: p95_25 <= 1.5 x p95_10 + 1 ms\(enforced ? "" : ", not enforced here"))
        cold committed 25 KB layout+set (median) = \(String(format: "%.2f", cold)) ms; p95 live / cold = \(String(format: "%.3f", relative)) (limit 0.25\(enforced ? "" : ", not enforced here"))
        120 Hz frame target 8.3 ms p95 at 25 KB: \(frameMet ? "MET" : "NOT MET") (\(String(format: "%.2f", p25)) ms)

        """)
        // Baseline (no coalescer) is expected to be slow; the checks only apply once flush is wired.
        guard ProbeShim.flush != nil else { return }
        // Deterministic: publishes follow the requested simulated cadence, independent of machine speed.
        for (kb, r) in results.sorted(by: { $0.key < $1.key }) {
            let expected = Int(ceil(Double(r.tokens) * Double(r.cadenceHz) / 60))
            #expect(r.publishes.count == expected, "\(kb) KB: \(r.publishes.count) publishes at \(r.cadenceHz) Hz for \(r.tokens) tokens")
        }
        #if os(macOS)
        // Deterministic flatness: each publish re-sets only the text parts that changed (the growing tail),
        // so the most set in one publish doesn't grow with the reply's size.
        let sets10 = results[10]?.textSets.max() ?? 0, sets25 = results[25]?.textSets.max() ?? 0
        // (Up to 3: a publish can close a text part, cross a code block, and start the next text part.)
        #expect(sets25 <= 3, "a publish at 25 KB re-set \(sets25) text views; only the growing tail should change")
        #expect(sets25 <= sets10, "text views re-set per publish grew with size: \(sets10) at 10 KB, \(sets25) at 25 KB")
        #endif
        // Wall-clock ratios only mean something with the CPU to ourselves: see `PerfBudget.enforcesWallClockRatios`.
        if enforced {
            #expect(p25 <= 1.5 * p10 + 1, "p95 not flat: 25 KB \(p25) ms vs 10 KB \(p10) ms")
            #expect(p25 <= 0.25 * cold, "p95 live publish \(p25) ms is more than 0.25x the cold committed cost \(cold) ms")
        }
        if ProcessInfo.processInfo.environment["PINCER_FRAME_BUDGET"] == "1" {
            let limit = PerfBudget.limit(.milliseconds(8.3))
            #expect(Duration.seconds(p25 / 1000) <= limit, "p95 publish at 25 KB \(p25) ms, budget \(limit)")
        }
    }

    @Test func pairedThirtyAndSixtyHzCadenceAt25KB() {
        let thirty = self.run(bytes: 25_000, cadenceHz: 30)
        let sixty = self.run(bytes: 25_000, cadenceHz: 60)
        func p95(_ result: Result) -> Double { Self.p95(result.publishes) }
        func maximum(_ result: Result) -> Double { result.publishes.max() ?? 0 }
        func summary(_ result: Result) -> String {
            "\(result.cadenceHz) Hz: \(result.publishes.count) publishes, p95 \(String(format: "%.2f", p95(result))) ms, " +
                "max \(String(format: "%.2f", maximum(result))) ms, publish total \(String(format: "%.2f", result.publishTotalMs)) ms, " +
                "event+publish total \(String(format: "%.2f", result.totalMs)) ms, max text sets \(result.textSets.max() ?? 0), " +
                "final UTF-8 bytes \(result.finalText.utf8.count)"
        }
        print("\nStreaming cadence pair (25 KB, 60 chunks/s):\n\(summary(thirty))\n\(summary(sixty))\n")

        let expectedText = Self.reply(bytes: 25_000)
        #expect(thirty.finalText == expectedText)
        #expect(sixty.finalText == expectedText)
        #expect(thirty.tokens == sixty.tokens)
        #expect(thirty.publishes.count == Int(ceil(Double(thirty.tokens) / 2)))
        #expect(sixty.publishes.count == sixty.tokens)
        #expect(sixty.publishTotalMs >= 0 && thirty.publishTotalMs >= 0)
        #if os(macOS)
        #expect((thirty.textSets.max() ?? 0) <= 3)
        #expect((sixty.textSets.max() ?? 0) <= 3)
        #endif
        if ProcessInfo.processInfo.environment["PINCER_FRAME_BUDGET"] == "1" {
            let limit = PerfBudget.limit(.milliseconds(8.3))
            let p95 = Duration.seconds(Self.p95(sixty.publishes) / 1000)
            #expect(p95 <= limit, "60 Hz publish p95 \(p95) exceeds the 120 Hz frame budget \(limit)")
        }
    }
}
