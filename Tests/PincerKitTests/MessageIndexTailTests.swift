import Foundation
import Testing
@testable import PincerKit

/// Tail indexing (#199): indexing only what follows an unchanged prefix gives the same rows,
/// positions and search results as indexing the whole transcript.
@Suite("Message index tail", .serialized)
struct MessageIndexTailTests {
    struct Generator {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            self.state = self.state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((self.state >> 33) % UInt64(bound))
        }

        /// One or more items: a user message, a marker, or an assistant turn that may span several
        /// items (text, thinking, tool calls, results, more text) in one or two runs.
        mutating func group(_ number: Int) -> [ChatItem] {
            let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(number) * 10)
            func item(_ suffix: String, _ role: ChatRole, _ blocks: [ContentBlock]) -> ChatItem {
                var item = ChatItem(id: "g\(number)\(suffix)", role: role, blocks: blocks, timestamp: stamp)
                item.transcriptId = item.id
                return item
            }
            switch self.next(10) {
            case 0, 1, 2:
                return [item("u", .user, [.text("question \(number) about tail indexing")])]
            case 3 where number > 0:
                var marker = item("m", .marker, [])
                marker.markerKind = self.next(2) == 0 ? "compaction" : "reset"
                return [marker]
            case 4:
                return [item("s", .system, [.text("system \(number)")])]
            default:
                let run = "run\(number / 3)"
                var items: [ChatItem] = []
                for part in 0...self.next(4) {
                    var assistant = item("a\(part)", .assistant, [.thinking("hmm \(part)"), .text("answer \(number).\(part) alpha")])
                    assistant.runId = run
                    if self.next(3) == 0 {
                        assistant.blocks.append(.toolCall(id: "c\(number)-\(part)", name: "exec", arguments: "{}"))
                        items.append(assistant)
                        var result = item("r\(part)", .toolResult, [.text("output \(number)")])
                        result.toolCallId = "c\(number)-\(part)"
                        result.runId = run
                        items.append(result)
                    } else {
                        items.append(assistant)
                    }
                }
                if self.next(6) == 0 {
                    var other = item("o", .assistant, [.text("from cron \(number)")])
                    other.runId = "cron\(number)"
                    other.sender = MessageSender(kind: .automation, label: "cron")
                    items.append(other)
                }
                return items
            }
        }

        mutating func items(groups: Int) -> [ChatItem] {
            (0..<groups).flatMap { self.group($0) }
        }
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "pincer-tail-\(UUID().uuidString)", directoryHint: .isDirectory)
    let key = "agent:main:tail"

    /// `sessionKey`'s transcript file, so the index doesn't skip it as removed.
    func touchFile(_ gateway: UUID, key: String) throws {
        let file = try #require(TranscriptCache.file(gatewayId: gateway, sessionKey: key, root: self.root))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8))
    }

    func snapshot(_ items: [ChatItem]) -> TranscriptCache.Snapshot {
        TranscriptCache.Snapshot(items: items, complete: true)
    }

    func firstDifference(_ old: [ChatItem], _ new: [ChatItem]) -> Int {
        var index = 0
        while index < min(old.count, new.count), old[index] == new[index] { index += 1 }
        return index
    }

    /// Indexes `old` in full, then `new` as a tail, and `new` in full elsewhere; the rows and
    /// search results must agree, and the tail must have taken the tail path.
    func check(old: [ChatItem], new: [ChatItem], expectTail: Bool? = true, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let tailGateway = UUID()
        let fullGateway = UUID()
        try self.touchFile(tailGateway, key: self.key)
        try self.touchFile(fullGateway, key: self.key)
        let tailIndex = MessageIndex.shared(gatewayId: tailGateway, root: self.root)
        let fullIndex = MessageIndex.shared(gatewayId: fullGateway, root: self.root)
        await tailIndex.index(sessionKey: self.key, snapshot: self.snapshot(old), fileMtime: Date(), change: .full(token: "t0"))
        let prefix = self.firstDifference(old, new)
        await tailIndex.index(sessionKey: self.key, snapshot: self.snapshot(new), fileMtime: Date().addingTimeInterval(1),
                              change: .tail(unchangedPrefix: prefix, baseToken: "t0", token: "t1"))
        await fullIndex.index(sessionKey: self.key, snapshot: self.snapshot(new), fileMtime: Date().addingTimeInterval(1))
        #expect(await tailIndex.indexedRows(sessionKey: self.key) == fullIndex.indexedRows(sessionKey: self.key), sourceLocation: sourceLocation)
        if let expectTail { #expect(await tailIndex.lastIndexStats.path == (expectTail ? .tail : .full), sourceLocation: sourceLocation) }
        #expect(await tailIndex.chatToken(sessionKey: self.key) == "t1", sourceLocation: sourceLocation)
        #expect(try await tailIndex.search("alpha").map(\.entryId) == fullIndex.search("alpha").map(\.entryId), sourceLocation: sourceLocation)
        #expect(try await tailIndex.search("question").map(\.entryId) == fullIndex.search("question").map(\.entryId), sourceLocation: sourceLocation)
        let expected = MessageSearch.positionedDocuments(sessionKey: self.key, items: new[...]).count
        #expect(await tailIndex.indexedRows(sessionKey: self.key).count == expected, sourceLocation: sourceLocation)
        let info = await tailIndex.chatInfo(sessionKey: self.key)
        #expect(info?.itemCount == new.count, sourceLocation: sourceLocation)
        #expect(info?.lastItemId == new.last?.id, sourceLocation: sourceLocation)
        await MessageIndex.shutdown(root: self.root)
    }

    @Test func suffixBuildEqualsFullBuildFromEveryBoundary() {
        var generator = Generator(state: 7)
        for round in 0..<40 {
            var items = generator.items(groups: 30)
            if round % 5 == 0 { items[items.count / 2].isPending = true }
            let full = MessageSearch.positionedDocuments(sessionKey: "k", items: items[...])
            for prefix in stride(from: 0, to: items.count, by: 3) {
                let start = MessageSearch.rowBoundary(items: items, before: prefix)
                #expect(start <= max(prefix - 1, 0))
                let suffix = MessageSearch.positionedDocuments(sessionKey: "k", items: items[start...])
                let expected = full.filter { $0.pos >= start }
                #expect(suffix.map(\.document) == expected.map(\.document))
                #expect(suffix.map(\.pos) == expected.map(\.pos))
            }
        }
    }

    @Test func appendsMatchFullIndexing() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 1)
        let items = generator.items(groups: 60)
        for cut in [items.count - 1, items.count - 3, items.count / 2] {
            try await self.check(old: Array(items[..<cut]), new: items)
        }
    }

    @Test func editingTheLastItemMatchesFullIndexing() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 2)
        let items = generator.items(groups: 50)
        var edited = items
        let last = edited.count - 1
        edited[last].blocks = [.text("rewritten alpha text")]
        try await self.check(old: items, new: edited)
        edited = items
        edited.append(edited[last])
        edited[edited.count - 1].id = "extra"
        edited[edited.count - 1].blocks = [.text("streamed alpha")]
        try await self.check(old: items, new: edited)
    }

    @Test func toolResultsAndMarkersAtTheTailMatchFullIndexing() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 3)
        var items = generator.items(groups: 20)
        var call = ChatItem(id: "zc", role: .assistant, blocks: [.text("running alpha"), .toolCall(id: "zc1", name: "exec", arguments: nil)])
        call.runId = "zrun"
        items.append(call)
        let old = items
        var result = ChatItem(id: "zr", role: .toolResult, blocks: [.text("done")])
        result.toolCallId = "zc1"
        result.runId = "zrun"
        items.append(result)
        try await self.check(old: old, new: items)
        var more = ChatItem(id: "zm", role: .marker, blocks: [])
        more.markerKind = "compaction"
        let withResult = items
        items.append(more)
        try await self.check(old: withResult, new: items)
    }

    @Test func randomEditsMatchFullIndexing() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 4)
        for _ in 0..<12 {
            let old = generator.items(groups: 25 + generator.next(20))
            var new = old
            switch generator.next(4) {
            case 0: new += generator.group(1000)
            case 1: new.removeLast(min(new.count - 1, 1 + generator.next(4)))
            case 2:
                let at = generator.next(new.count)
                new[at].blocks = [.text("changed alpha \(at)")]
            default: new.insert(contentsOf: generator.group(2000), at: new.count / 2)
            }
            try await self.check(old: old, new: new)
        }
    }

    @Test func pendingItemsAtTheTailMatchFullIndexing() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 5)
        let old = generator.items(groups: 20)
        var pending = ChatItem(id: "pend", role: .user, blocks: [.text("question pending")], isPending: true)
        pending.transcriptId = nil
        try await self.check(old: old, new: old + [pending])
        try await self.check(old: old + [pending], new: old)
    }

    @Test func tokenMismatchFallsBackToFull() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 6)
        let items = generator.items(groups: 30)
        let gateway = UUID()
        try self.touchFile(gateway, key: self.key)
        let index = MessageIndex.shared(gatewayId: gateway, root: self.root)
        await index.index(sessionKey: self.key, snapshot: self.snapshot(items), fileMtime: Date(), change: .full(token: "a"))
        let more = items + generator.group(500)
        await index.index(sessionKey: self.key, snapshot: self.snapshot(more), fileMtime: Date().addingTimeInterval(1),
                          change: .tail(unchangedPrefix: items.count, baseToken: "other", token: "b"))
        #expect(await index.lastIndexStats.path == .full)
        #expect(await index.chatToken(sessionKey: self.key) == "b")
        #expect(await index.indexedRows(sessionKey: self.key).count == MessageSearch.documents(sessionKey: self.key, items: more).count)
        // A prefix longer than what was indexed can't be trusted either.
        await index.index(sessionKey: self.key, snapshot: self.snapshot(more), fileMtime: Date().addingTimeInterval(2),
                          change: .tail(unchangedPrefix: more.count + 5, baseToken: "b", token: "c"))
        #expect(await index.lastIndexStats.path != .tail)
        // A chat that was never indexed has no base, so it's indexed in full.
        try self.touchFile(gateway, key: "other")
        await index.index(sessionKey: "other", snapshot: self.snapshot(items), fileMtime: Date(),
                          change: .tail(unchangedPrefix: 1, baseToken: "b", token: "d"))
        #expect(await index.lastIndexStats.path == .full)
        #expect(await index.chatToken(sessionKey: "other") == "d")
        #expect(await index.indexedRows(sessionKey: "other").count == MessageSearch.documents(sessionKey: "other", items: items).count)
        await MessageIndex.shutdown(root: self.root)
    }

    @Test func tailBuildsOnlyTheLastRow() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 8)
        let items = generator.items(groups: 400)
        let gateway = UUID()
        try self.touchFile(gateway, key: self.key)
        let index = MessageIndex.shared(gatewayId: gateway, root: self.root)
        await index.index(sessionKey: self.key, snapshot: self.snapshot(items), fileMtime: Date(), change: .full(token: "a"))
        let full = await index.lastIndexStats
        #expect(full.path == .full)
        var user = ChatItem(id: "new", role: .user, blocks: [.text("question latest")])
        user.transcriptId = "new"
        await index.index(sessionKey: self.key, snapshot: self.snapshot(items + [user]), fileMtime: Date().addingTimeInterval(1),
                          change: .tail(unchangedPrefix: items.count, baseToken: "a", token: "b"))
        let stats = await index.lastIndexStats
        #expect(stats.path == .tail)
        #expect(stats.documentsBuilt == 1)
        #expect(stats.rowsRead == 0)
        #expect(stats.rowsWritten == 1)
        #expect(full.documentsBuilt > 100)
        await MessageIndex.shutdown(root: self.root)
    }

    /// A windowed save hands over only the newest items; the result equals indexing them all.
    @Test func offsetTailEqualsFullTail() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 11)
        var outcomes: [MessageIndex.IndexOutcome] = []
        for round in 0..<10 {
            let old = generator.items(groups: 40)
            var new = old
            if round % 2 == 0 { new += generator.group(3000 + round) } else { new[new.count - 1].blocks = [.text("edited alpha")] }
            let prefix = self.firstDifference(old, new)
            let offset = generator.next(new.count)
            let windowed = UUID()
            let whole = UUID()
            for gateway in [windowed, whole] { try self.touchFile(gateway, key: self.key) }
            let windowedIndex = MessageIndex.shared(gatewayId: windowed, root: self.root)
            let wholeIndex = MessageIndex.shared(gatewayId: whole, root: self.root)
            for index in [windowedIndex, wholeIndex] {
                await index.index(sessionKey: self.key, snapshot: self.snapshot(old), fileMtime: Date(), change: .full(token: "a"))
            }
            let change = IndexChange.tail(unchangedPrefix: prefix, baseToken: "a", token: "b")
            let outcome = await windowedIndex.index(sessionKey: self.key, items: Array(new[offset...]), itemOffset: offset,
                                                    totalCount: new.count, fileMtime: Date().addingTimeInterval(1), change: change)
            outcomes.append(outcome)
            await wholeIndex.index(sessionKey: self.key, snapshot: self.snapshot(new), fileMtime: Date().addingTimeInterval(1),
                                   change: change)
            if outcome == .done {
                #expect(await windowedIndex.lastIndexStats.path == .tail)
                #expect(await windowedIndex.indexedRows(sessionKey: self.key) == wholeIndex.indexedRows(sessionKey: self.key))
                #expect(await windowedIndex.chatToken(sessionKey: self.key) == "b")
                #expect(await windowedIndex.chatInfo(sessionKey: self.key)?.itemCount == new.count)
            } else {
                // Nothing was written; the whole transcript still applies.
                #expect(await windowedIndex.chatToken(sessionKey: self.key) == "a")
                await windowedIndex.index(sessionKey: self.key, snapshot: self.snapshot(new), fileMtime: Date().addingTimeInterval(1),
                                          change: change)
                #expect(await windowedIndex.indexedRows(sessionKey: self.key) == wholeIndex.indexedRows(sessionKey: self.key))
            }
            await MessageIndex.shutdown(root: self.root)
        }
        #expect(outcomes.contains(.done))
    }

    @Test func offsetEntryAsksForEarlierItems() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 12)
        let items = generator.items(groups: 30)
        let gateway = UUID()
        try self.touchFile(gateway, key: self.key)
        let index = MessageIndex.shared(gatewayId: gateway, root: self.root)
        await index.index(sessionKey: self.key, snapshot: self.snapshot(items), fileMtime: Date(), change: .full(token: "a"))
        let offset = items.count - 2
        let window = Array(items[offset...])
        let later = Date().addingTimeInterval(1)
        // A full change, a stale base, a prefix before the window, and a mismatched count all need more.
        var outcomes: [MessageIndex.IndexOutcome] = []
        outcomes.append(await index.index(sessionKey: self.key, items: window, itemOffset: offset, totalCount: items.count,
                                          fileMtime: later, change: .full(token: "b")))
        outcomes.append(await index.index(sessionKey: self.key, items: window, itemOffset: offset, totalCount: items.count,
                                          fileMtime: later, change: .tail(unchangedPrefix: items.count, baseToken: "x", token: "b")))
        outcomes.append(await index.index(sessionKey: self.key, items: window, itemOffset: offset, totalCount: items.count,
                                          fileMtime: later, change: .tail(unchangedPrefix: 0, baseToken: "a", token: "b")))
        outcomes.append(await index.index(sessionKey: self.key, items: window, itemOffset: offset, totalCount: items.count + 1,
                                          fileMtime: later, change: .tail(unchangedPrefix: items.count, baseToken: "a", token: "b")))
        #expect(outcomes.allSatisfy { $0 == .needsEarlierItems })
        #expect(await index.chatToken(sessionKey: self.key) == "a")
        // Offset zero is the whole transcript.
        let done = await index.index(sessionKey: self.key, items: items, itemOffset: 0, totalCount: items.count,
                                     fileMtime: later, change: .full(token: "c"))
        #expect(done == .done)
        #expect(await index.chatToken(sessionKey: self.key) == "c")
        await MessageIndex.shutdown(root: self.root)
    }

    /// The first changed item may replace one that belonged to an earlier row in the old transcript.
    @Test func changedItemStartingANewRowDropsTheOldRowsLaterMessages() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        func item(_ id: String, _ role: ChatRole, _ text: String) -> ChatItem {
            var item = ChatItem(id: id, role: role, blocks: [.text(text)], timestamp: Date(timeIntervalSince1970: 1_700_000_000))
            item.transcriptId = id
            item.runId = role == .assistant ? "r" : nil
            return item
        }
        let user = item("U0", .user, "question alpha")
        let first = item("A1", .assistant, "one alpha")
        var second = item("A2", .assistant, "two alpha")
        second.blocks = [.text("two alpha")]
        try await self.check(old: [user, first, second], new: [user, first, item("U3", .user, "question three")])
        try await self.check(old: [user, first, second], new: [user, item("U3", .user, "question three")])
        try await self.check(old: [user, first, second], new: [item("U3", .user, "question three")])
    }

    @Test func randomReplacementsMatchFullIndexing() async throws {
        defer { try? FileManager.default.removeItem(at: self.root) }
        var generator = Generator(state: 21)
        for _ in 0..<25 {
            let old = generator.items(groups: 12 + generator.next(10))
            let keep = generator.next(old.count + 1)
            let new = Array(old[..<keep]) + generator.items(groups: generator.next(6)).map { item in
                var item = item
                item.id = "n" + item.id
                item.transcriptId = item.id
                return item
            }
            try await self.check(old: old, new: new, expectTail: nil)
        }
    }
}
