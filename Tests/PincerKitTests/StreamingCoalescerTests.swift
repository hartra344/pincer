import Foundation
import Testing
@testable import PincerKit

/// Serialized because `ChatStore.liveFlushInterval` is process-wide.
@MainActor
@Suite("Streaming coalescer", .serialized)
struct StreamingCoalescerTests {
    let scratch = ScratchDefaults()
    static let key = "agent:coalesce:main"

    func chat() -> ChatStore {
        GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                     defaults: self.scratch.defaults, identity: Fixtures.identity()).chat(for: Self.key)
    }

    static func assistant(_ text: String) -> JSONValue {
        ["role": "assistant", "content": .array([["type": "text", "text": .string(text)]])]
    }

    func chatEvent(_ chat: ChatStore, _ fields: [String: JSONValue], run: String = "run_1") {
        var payload = fields
        payload["runId"] = .string(run)
        payload["sessionKey"] = .string(Self.key)
        chat.handleChat(.object(payload))
    }

    func delta(_ chat: ChatStore, _ chunk: String, full: String, replace: Bool = false) {
        var fields: [String: JSONValue] = ["state": "delta", "deltaText": .string(chunk), "message": Self.assistant(full)]
        if replace { fields["replace"] = true }
        self.chatEvent(chat, fields)
    }

    func toolEvent(_ chat: ChatStore, phase: String, id: String = "call_1") {
        var data: [String: JSONValue] = ["phase": .string(phase), "name": "exec", "toolCallId": .string(id)]
        if phase == "start" { data["args"] = ["command": "ls"] } else { data["isError"] = false; data["result"] = "ok" }
        chat.handleAgent(["runId": "run_1", "sessionKey": .string(Self.key), "stream": "tool", "data": .object(data)])
    }

    func liveText(_ chat: ChatStore) -> String? {
        for entry in chat.entries.reversed() {
            if case let .assistant(turn) = entry, turn.isStreaming { return turn.body }
        }
        return nil
    }

    func withInterval<T>(_ interval: TimeInterval, _ body: () async throws -> T) async rethrows -> T {
        let saved = ChatStore.liveFlushInterval
        ChatStore.liveFlushInterval = interval
        defer { ChatStore.liveFlushInterval = saved }
        return try await body()
    }

    @Test func runStartAndFirstDeltaPublishImmediately() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.chatEvent(chat, ["state": "status", "phase": "starting_model"])
            self.delta(chat, "A", full: "A")
            #expect(self.liveText(chat) == "A")
        }
    }

    @Test func burstIsCoalescedThenTrailingFlushPublishes() async {
        defer { self.scratch.remove() }
        await self.withInterval(0.5) {
            let chat = self.chat()
            self.delta(chat, "A", full: "A")
            #expect(self.liveText(chat) == "A")
            var full = "A"
            for c in ["B", "C", "D", "E"] { full += c; self.delta(chat, c, full: full) }
            // Within the interval: stored but not yet published.
            #expect(self.liveText(chat) == "A")
            // Await the scheduled trailing flush itself rather than a wall-clock deadline: on a starved
            // runner the main actor may not get to it for seconds.
            let trailing = chat.pendingFlush
            #expect(trailing != nil, "a trailing flush is scheduled")
            await trailing?.value
            #expect(self.liveText(chat) == "ABCDE")
        }
    }

    @Test func leadingEdgePublishesAfterQuietInterval() async {
        defer { self.scratch.remove() }
        await self.withInterval(0.05) {
            let chat = self.chat()
            self.delta(chat, "A", full: "A")
            try? await Task.sleep(for: .milliseconds(120))
            self.delta(chat, "B", full: "AB")
            #expect(self.liveText(chat) == "AB")
        }
    }

    @Test func flushLivePublishesPendingNow() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "A", full: "A")
            self.delta(chat, "B", full: "AB")
            #expect(self.liveText(chat) == "A")
            chat.flushLive()
            #expect(self.liveText(chat) == "AB")
            chat.flushLive()
            #expect(self.liveText(chat) == "AB")
        }
    }

    @Test func replaceDeltaIsNeverDelayed() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "A", full: "A")
            self.delta(chat, "B", full: "AB")
            self.delta(chat, "", full: "Fresh", replace: true)
            #expect(self.liveText(chat) == "Fresh")
        }
    }

    @Test func liveReplyStripsTransportDirectiveAndKeepsCodeLiteral() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let text = "[[reply_to:message-1]] Recovered `[[reply_to_current]]` response"
            self.delta(chat, text, full: text)
            #expect(self.liveText(chat) == "Recovered `[[reply_to_current]]` response")
        }
    }

    @Test func multipleReplyDirectivesInOneFrameAreRemovedInOnePass() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let text = "[[reply_to:first]] First [[reply_to:second]] second"
            self.chatEvent(chat, ["state": "delta", "deltaText": .string(text)])
            #expect(self.liveText(chat) == "First  second")
        }
    }

    @Test func replyDirectiveAfterMultibytePrefixUsesUTF8Offsets() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let text = "🧭 [[reply_to_current]] Recovered"
            self.chatEvent(chat, ["state": "delta", "deltaText": .string(text)])
            #expect(self.liveText(chat) == "🧭  Recovered")
        }
    }

    @Test func liveReplyStripsDirectiveSplitAcrossSnapshotAndAppend() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let prefix = "[[reply_to_current"
            self.delta(chat, prefix, full: prefix)
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("]] Recovered response")])
            chat.flushLive()
            #expect(self.liveText(chat) == "Recovered response")
        }
    }

    @Test func replyDirectiveCloseDelimiterCanSplitAcrossFrames() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let prefix = "[[reply_to_current]"
            self.delta(chat, prefix, full: prefix)
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("] Recovered response")])
            chat.flushLive()
            #expect(self.liveText(chat) == "Recovered response")
        }
    }

    @Test func pendingDirectiveOffsetTracksEarlierRemovalInSameFrame() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("[[reply_to_current]] Some [[reply_to:")])
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("second]] Reply")])
            chat.flushLive()
            #expect(self.liveText(chat) == "Some  Reply")
            #expect(chat.live?.pendingReplyDirective == nil)
        }
    }

    @Test func splitReplyMarkerInsideInlineCodeRemainsLiteral() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let prefix = "Use `[[reply_to_current"
            self.delta(chat, prefix, full: prefix)
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("]]` literally")])
            chat.flushLive()
            #expect(self.liveText(chat) == "Use `[[reply_to_current]]` literally")
        }
    }

    @Test func splitReplyMarkerInsideFenceRemainsLiteral() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let prefix = "```text\n[[reply_to_current"
            self.delta(chat, prefix, full: prefix)
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("]]\n```")])
            chat.flushLive()
            #expect(self.liveText(chat) == "```text\n[[reply_to_current]]\n```")
        }
    }

    @Test func replyMarkerInCodeOpenedByEarlierFramesRemainsLiteral() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "```swift\n", full: "```swift\n")
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("[[reply_to_current")])
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("]]\n```")])
            chat.flushLive()
            #expect(self.liveText(chat) == "```swift\n[[reply_to_current]]\n```")
        }
    }

    @Test func replyMarkerInInlineCodeOpenedByEarlierFrameRemainsLiteral() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "`", full: "`")
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("[[reply_to_current")])
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("]]` literal")])
            chat.flushLive()
            #expect(self.liveText(chat) == "`[[reply_to_current]]` literal")
        }
    }

    @Test func emptyInitialSnapshotDeltaStillEstablishesFenceContext() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "", full: "```swift\n")
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("[[reply_to_current")])
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("]]\n```")])
            chat.flushLive()
            #expect(self.liveText(chat) == "```swift\n[[reply_to_current]]\n```")
        }
    }

    @Test func openingReplyMarkerSplitAcrossFramesIsStripped() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "[", full: "[")
            self.chatEvent(chat, ["state": "delta", "deltaText": .string("[reply_to_current]] Recovered response")])
            chat.flushLive()
            #expect(self.liveText(chat) == "Recovered response")
        }
    }

    @Test func snapshotlessReplaceStripsCompleteReplyDirective() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.chatEvent(chat, ["state": "delta", "replace": true,
                                  "deltaText": .string("[[reply_to:message-1]] Recovered response")])
            chat.flushLive()
            #expect(self.liveText(chat) == "Recovered response")
        }
    }

    @Test func oldLiteralMarkerDoesNotArmLaterCloseFrames() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let prefix = "Use `[[reply_to_current]]` as literal syntax"
            self.delta(chat, prefix, full: prefix)
            let parsedBeforeClosers = chat.live?.replyDirectiveParseBytes
            let lexedBeforeClosers = chat.live?.replyDirectiveLexBytes ?? 0
            for _ in 0..<20 {
                self.chatEvent(chat, ["state": "delta", "deltaText": .string("]] ")])
            }
            chat.flushLive()
            #expect(chat.live?.pendingReplyDirective == nil)
            #expect(chat.live?.replyDirectiveParseBytes == parsedBeforeClosers)
            #expect(chat.live?.replyDirectiveLexBytes == lexedBeforeClosers + 60)
            #expect(self.liveText(chat) == prefix + String(repeating: "]] ", count: 20))
        }
    }

    @Test func manyUnrelatedMarkersDoNotCopyOrParseFrameSuffixes() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let frame = String(repeating: "[[ordinary]] and ]] ", count: 2_000)
            self.chatEvent(chat, ["state": "delta", "deltaText": .string(frame)])
            chat.flushLive()
            #expect(chat.live?.replyDirectiveParseBytes == 0)
            #expect((chat.live?.replyDirectiveLexBytes ?? 0) > frame.utf8.count,
                    "the scan counter includes bounded prefix lookahead for each opener")
            #expect((chat.live?.replyDirectiveLexBytes ?? .max) <= frame.utf8.count * 2,
                    "lookahead remains linear in this large frame")
            #expect(self.liveText(chat) == frame)
        }
    }

    @Test func repeatedUnclosedReplyPrefixesHaveBoundedParseCost() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            let frame = String(repeating: "[[reply_to:", count: 1_200)
            self.chatEvent(chat, ["state": "delta", "deltaText": .string(frame)])
            chat.flushLive()
            #expect(self.liveText(chat) == frame)
            #expect((chat.live?.replyDirectiveParseBytes ?? .max) <= frame.utf8.count + 4_096,
                    "overlapping incomplete candidates do not reparse each remaining suffix")
        }
    }

    @Test func toolEventsFlushPendingTextImmediately() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "A", full: "A")
            self.delta(chat, "B", full: "AB")
            #expect(self.liveText(chat) == "A")
            self.toolEvent(chat, phase: "start")
            #expect(self.liveText(chat) == "AB")
            let toolCount: () -> Int = {
                for case let .assistant(turn) in chat.entries where turn.isStreaming { return turn.tools.count }
                return 0
            }
            #expect(toolCount() == 1)
            self.delta(chat, "C", full: "ABC")
            self.toolEvent(chat, phase: "result")
            #expect(self.liveText(chat) == "ABC")
        }
    }

    @Test func runEndFlushesPendingText() async {
        defer { self.scratch.remove() }
        await self.withInterval(5) {
            let chat = self.chat()
            self.delta(chat, "A", full: "A")
            self.delta(chat, "B", full: "AB")
            chat.handleAgent(["runId": "run_1", "sessionKey": .string(Self.key), "stream": "lifecycle",
                              "data": ["phase": "end"]])
            #expect(self.liveText(chat) == "AB" || self.liveText(chat) == nil)
            if self.liveText(chat) == nil {
                #expect(!chat.entries.contains { if case let .assistant(t) = $0 { t.isStreaming } else { false } })
            }
        }
    }

    @Test func coalescedFinalStateEqualsUncoalesced() async {
        defer { self.scratch.remove() }
        let text = String(repeating: "Hello **world**, streaming tokens.\n\n- item\n", count: 20)
        let chunks = stride(from: 0, to: text.count, by: 7).map {
            String(text.dropFirst($0).prefix(7))
        }
        func run(interval: TimeInterval) async -> [TranscriptEntry] {
            await self.withInterval(interval) {
                let chat = self.chat()
                self.chatEvent(chat, ["state": "status", "phase": "starting_model"])
                var full = ""
                for c in chunks { full += c; self.delta(chat, c, full: full) }
                chat.flushLive()
                return chat.entries
            }
        }
        let plain = await run(interval: 0)
        let coalesced = await run(interval: 5)
        #expect(plain.count == coalesced.count)
        // Live ids embed the run id and start time; compare the visible turn contents.
        func bodies(_ entries: [TranscriptEntry]) -> [String] {
            entries.compactMap { if case let .assistant(t) = $0 { t.body } else { nil } }
        }
        #expect(bodies(plain) == bodies(coalesced))
        #expect(bodies(plain).last == text)
    }
}
