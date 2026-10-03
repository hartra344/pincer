import Foundation
import Testing
@testable import PincerKit


private actor QuotePreparationGate {
    private let id: String
    private var entered = false
    private var released = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    init(id: String) { self.id = id }
    func hasEntered() -> Bool { self.entered }
    func arriveAndWait(_ id: String) async {
        guard id == self.id else { return }
        self.entered = true
        guard !self.released else { return }
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled { continuation.resume() }
                else { self.held[token] = continuation }
            }
        } onCancel: { Task { await self.cancel(token) } }
    }
    private func cancel(_ token: UUID) { self.held.removeValue(forKey: token)?.resume() }
    func release() {
        self.released = true
        let held = self.held.values
        self.held.removeAll()
        for continuation in held { continuation.resume() }
    }
}

@MainActor
@Suite("Quoted row preview preparation")
struct QuotePreviewPreparationTests {
    @MainActor
    private final class Fixture {
        let suite = "pincer.quote-preparation.\(UUID().uuidString)"
        let defaults: UserDefaults
        let gateway: GatewayStore
        let chat: ChatStore
        init(items: [ChatItem]) {
            let defaults = UserDefaults(suiteName: self.suite)!
            self.defaults = defaults
            self.gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Quote fixture", url: "ws://127.0.0.1:1", authMode: .none),
                                        defaults: defaults, identity: Fixtures.identity())
            self.gateway.cacheRoot = nil
            self.chat = ChatStore(sessionKey: "agent:main:quoted-preview", agentId: "main", gateway: self.gateway, headless: true)
            self.chat.quotePreviewPreparation = QuotePreviewPreparationService()
            self.chat.items = items
            self.chat.rebuild(itemsChanged: true)
        }
        func stop() {
            self.chat.stopQuotePreviewPublication()
            self.chat.quotePreviewNormalizationProbe = nil
            self.gateway.stop()
            self.defaults.removePersistentDomain(forName: self.suite)
        }
    }

    private func gated(_ gate: QuotePreparationGate, _ operation: () async throws -> Void) async throws {
        do { try await operation(); await gate.release() }
        catch { await gate.release(); throw error }
    }

    private func waitForEntry(_ gate: QuotePreparationGate) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await gate.hasEntered()) {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline, "The admitted actual quote worker did not enter its exact-ID gate")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func pair(id: String, text: String, fallback: String? = nil) -> [ChatItem] {
        var target = ChatItem(id: "local-\(id)", role: .assistant, blocks: [.text(text)])
        target.transcriptId = id
        var reply = ChatItem(id: "reply-\(id)", role: .user, blocks: [.text("Explain that result")])
        reply.transcriptId = "reply-\(id)"
        reply.replyToId = id
        reply.replyToPreview = fallback.map { ReplyPreview(text: $0, senderLabel: "Recorded sender") }
        return [target, reply]
    }

    private static func items(loaded: Bool, large: Bool) async -> [ChatItem] {
        await Task.detached {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            var target = ChatItem(id: "local-target", role: .assistant,
                                  blocks: [.text("Meaningful **Disk** status\n\n")], timestamp: date)
            target.transcriptId = loaded ? "quoted-loaded-target" : "quoted-unloaded-target"
            if large {
                let chunk = String(repeating: "x", count: 262_144)
                target.blocks += (0..<8).map { .text("Block \($0) \(chunk)") }
            }
            var reply = ChatItem(id: "local-reply", role: .user, blocks: [.text("Can you explain that quote?")], timestamp: date.addingTimeInterval(1))
            reply.transcriptId = "quoted-reply"
            reply.replyToId = target.transcriptId
            reply.replyToPreview = ReplyPreview(text: large ? "Meaningful fallback status " + String(repeating: "y", count: 2 * 1024 * 1024) : "Meaningful fallback status", senderLabel: "Maya")
            return loaded ? [target, reply] : [reply]
        }.value
    }

    @Test(.timeLimit(.minutes(2)), arguments: [true, false])
    func actualQuoteDoesNotJoinOrNormalizeLargeLoadedOrFallbackTextOnMain(_ loaded: Bool) async throws {
        let items = await Self.items(loaded: loaded, large: true)
        let fixture = Fixture(items: items)
        defer { fixture.stop() }
        let reply = try #require(items.last)
        let targetID = try #require(reply.replyToId)
        let probe = QuotePreviewNormalizationProbe(messageIDs: [targetID])
        fixture.chat.quotePreviewNormalizationProbe = probe
        let cold = try #require(fixture.chat.quote(for: reply)) // Actual interaction schedules preparation.
        #expect(cold.targetId == targetID)
        #expect(cold.sender == (loaded ? .agent : .label("Maya")))
        await fixture.chat.waitForQuotePreviewPreparation()
        let ready = try #require(fixture.chat.quote(for: reply))
        let text = try #require(ready.text)
        #expect(text.hasPrefix(loaded ? "Meaningful Disk status" : "Meaningful fallback status"))
        #expect(!text.isEmpty)
        #expect(probe.snapshot().mainCount == 0, "Actual quote joining/directive extraction/normalization must run off-main")
        #expect(probe.snapshot().offMainCount > 0, "An actual cold worker must prepare meaningful text, not an empty placeholder")
        #expect(text.count <= 280 && text.utf8.count <= 2048)
    }

    @Test(.timeLimit(.minutes(2))) func actualShortQuoteIsInstrumentedAndPreservesIdentitySenderAndOpening() async throws {
        let items = await Self.items(loaded: true, large: false)
        let fixture = Fixture(items: items)
        defer { fixture.stop() }
        let reply = try #require(items.last)
        let probe = QuotePreviewNormalizationProbe(messageIDs: ["quoted-loaded-target"])
        fixture.chat.quotePreviewNormalizationProbe = probe
        _ = fixture.chat.quote(for: reply)
        await fixture.chat.waitForQuotePreviewPreparation()
        let quote = try #require(fixture.chat.quote(for: reply))
        #expect(quote.targetId == "quoted-loaded-target" && quote.sender == .agent)
        #expect(quote.text == "Meaningful Disk status")
        #expect(items.first?.role == .assistant && reply.role == .user)
        #expect(items.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        let counts = probe.snapshot()
        #expect(counts.mainCount + counts.offMainCount > 0, "Actual short quote proves the normalization probe is armed")
    }
    @Test(.timeLimit(.minutes(2)), arguments: ["edit", "remove", "rehydrate", "stop"])
    func heldCompletionCannotPublishStaleHistoryOrLifecycle(_ change: String) async throws {
        let pair = Self.pair(id: "stale-quote", text: "Original quote opening", fallback: "Recorded replacement")
        let fixture = Fixture(items: pair)
        defer { fixture.stop() }
        let gate = QuotePreparationGate(id: "stale-quote")
        fixture.chat.quotePreviewPreparation.normalizationGate = { await gate.arriveAndWait($0) }
        try await self.gated(gate) {
            let cold = try #require(fixture.chat.quote(for: pair[1]))
            #expect(cold.targetId == "stale-quote" && cold.sender == .agent && cold.text == nil)
            try await self.waitForEntry(gate)
            switch change {
            case "edit":
                fixture.chat.items = Self.pair(id: "stale-quote", text: "Edited current opening", fallback: "Recorded replacement")
            case "remove": fixture.chat.items = [pair[1]]
            case "rehydrate":
                fixture.chat.items = []
                fixture.chat.rebuild(itemsChanged: true)
                fixture.chat.items = Self.pair(id: "stale-quote", text: "Rehydrated current opening")
            default: fixture.chat.stopQuotePreviewPublication()
            }
            if change != "stop" { fixture.chat.rebuild(itemsChanged: true) }
            let oldRevision = fixture.chat.quotePreviewRevision
            await gate.release()
            await fixture.chat.waitForQuotePreviewPreparation()
            #expect(fixture.chat.quotePreviewRevision == oldRevision, "An old held completion cannot publish after authority or lifecycle changes")
            if change != "stop" {
                _ = fixture.chat.quote(for: pair[1])
                await fixture.chat.waitForQuotePreviewPreparation()
                let current = try #require(fixture.chat.quote(for: pair[1]))
                let expected = change == "edit" ? "Edited current opening" : change == "remove" ? "Recorded replacement" : "Rehydrated current opening"
                #expect(current.text == expected)
                #expect(current.sender == (change == "remove" ? .label("Recorded sender") : .agent))
            }
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["empty", "thinking", "image", "tool", "whitespace-tail", "tags-tail", "directive"])
    func provenEmptyUsesRecordedTextButUnavailableOpeningNeverDoes(_ kind: String) async throws {
        let blocks: [ContentBlock] = await Task.detached {
            switch kind {
            case "thinking": return [.thinking("Private reasoning")]
            case "image": return [.image(ImageRef(artifactId: nil, base64: nil, url: "https://example.invalid/image.png", mimeType: "image/png", alt: nil, width: nil, height: nil))]
            case "tool": return [.toolCall(id: "quote-call", name: "read", arguments: nil)]
            case "whitespace-tail": return [.text(String(repeating: " ", count: 5_000) + "Meaningful later text")]
            case "tags-tail": return (0..<64).map { _ in .thinking("tag") } + [.text("Meaningful later text")]
            case "directive": return [.text("MEDIA:https://example.invalid/picture.png")]
            default: return [.text(" \n\t ")]
            }
        }.value
        var pair = Self.pair(id: "semantic-\(kind)", text: "unused", fallback: "Recorded **fallback**\n with whitespace")
        pair[0].blocks = blocks
        let fixture = Fixture(items: pair)
        defer { fixture.stop() }
        let cold = try #require(fixture.chat.quote(for: pair[1]))
        #expect(cold.targetId == "semantic-\(kind)" && cold.sender == .agent)
        await fixture.chat.waitForQuotePreviewPreparation()
        let ready = try #require(fixture.chat.quote(for: pair[1]))
        if kind == "whitespace-tail" || kind == "tags-tail" { #expect(ready.text == nil) }
        else { #expect(ready.text == "Recorded fallback with whitespace") }
        #expect(ready.text != "Image" && ready.text != "Attachment")
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["replacement", "boundary", "grapheme", "output-replacement"])
    func unicodeAndOutputBudgetsKeepMeaningfulSafeText(_ kind: String) async throws {
        let text = await Task.detached {
            switch kind {
            case "replacement": return "Literal\u{FFFD}"
            case "boundary": return String(repeating: "a", count: 4095) + "😀 later"
            case "grapheme": return "e" + String(repeating: "\u{301}", count: 3000)
            default: return String(repeating: "👨‍👩‍👧‍👦", count: 81) + String(repeating: "a", count: 20) + "\u{FFFD}" + String(repeating: "👨‍👩‍👧‍👦", count: 100)
            }
        }.value
        let pair = Self.pair(id: "unicode-\(kind)", text: text)
        let fixture = Fixture(items: pair)
        defer { fixture.stop() }
        let probe = QuotePreviewNormalizationProbe(messageIDs: ["unicode-\(kind)"])
        fixture.chat.quotePreviewNormalizationProbe = probe
        _ = fixture.chat.quote(for: pair[1])
        await fixture.chat.waitForQuotePreviewPreparation()
        let ready = try #require(fixture.chat.quote(for: pair[1]))
        let output = try #require(ready.text)
        #expect(output.count <= 280 && output.utf8.count <= 2048)
        #expect(probe.snapshot().mainCount == 0 && probe.snapshot().offMainCount > 0)
        if kind == "replacement" { #expect(output == "Literal\u{FFFD}") }
        if kind == "boundary" { #expect(output == String(repeating: "a", count: 280)) }
        if kind == "output-replacement" { #expect(output.utf8.count == 2048 && output.hasSuffix("\u{FFFD}")) }
        if kind == "grapheme" { #expect(output.unicodeScalars.first?.value == 0x65 && output.utf8.first == 0x65 && !output.contains("\u{FFFD}")) }
    }

    @Test(.timeLimit(.minutes(2))) func quoteQueueCountBytesAndCacheStayBoundedAcrossActualRequests() async throws {
        let pairs = (0..<35).map { Self.pair(id: "queue-\($0)", text: "Distinct short source \($0)") }
        let fixture = Fixture(items: pairs.flatMap { $0 })
        defer { fixture.stop() }
        let service = fixture.chat.quotePreviewPreparation
        let gate = QuotePreparationGate(id: "queue-0")
        service.normalizationGate = { await gate.arriveAndWait($0) }
        try await self.gated(gate) {
            _ = fixture.chat.quote(for: pairs[0][1])
            try await self.waitForEntry(gate)
            let canceledDrain = Task { await service.drain() }
            canceledDrain.cancel()
            await canceledDrain.value
            #expect(service.activeCount == 1, "Canceling one readiness waiter does not cancel admitted quote work")
            for pair in pairs.dropFirst() { _ = fixture.chat.quote(for: pair[1]) }
            try #require(service.activeCount == 1 && service.pendingCount == 32, "Short fixtures must fill the count budget before byte admission")
            #expect(service.pendingByteCount <= QuotePreviewPreparationService.pendingBytesLimit)
            #expect(service.watcherCount <= QuotePreviewPreparationService.watcherLimit)
            #expect(service.watcherByteCount <= QuotePreviewPreparationService.watcherBytesLimit)
            #expect(fixture.chat.quote(for: pairs[34][1])?.text == nil)
            await gate.release()
            await fixture.chat.waitForQuotePreviewPreparation()
            #expect(service.activeCount == 0 && service.pendingCount == 0 && service.watcherCount == 0)
        }
        for index in 0..<(QuotePreviewPreparationService.cacheLimit + 2) {
            let pair = Self.pair(id: "cache-\(index)", text: "Distinct cache source \(index)")
            fixture.chat.items = pair
            fixture.chat.rebuild(itemsChanged: true)
            _ = fixture.chat.quote(for: pair[1])
            await fixture.chat.waitForQuotePreviewPreparation()
        }
        #expect(service.cachedCount <= QuotePreviewPreparationService.cacheLimit)
        #expect(service.cachedByteCount <= QuotePreviewPreparationService.cacheBytesLimit)
        #expect(service.watcherCount == 0)
        let evicted = Self.pair(id: "cache-0", text: "Distinct cache source 0")
        fixture.chat.items = evicted
        fixture.chat.rebuild(itemsChanged: true)
        #expect(fixture.chat.quote(for: evicted[1])?.text == nil, "The oldest source is evicted rather than retained without limit")
        await fixture.chat.waitForQuotePreviewPreparation()
        #expect(fixture.chat.quote(for: evicted[1])?.text == "Distinct cache source 0")
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func coalescedWatchersAreBoundedAndStoppingOneOwnerKeepsAnotherAlive(_ largeInput: Bool) async throws {
        let text = await Task.detached { largeInput ? "Common coalesced opening " + String(repeating: "x", count: 5000) : "Common coalesced opening" }.value
        let fallback = largeInput ? text : nil
        let pair = Self.pair(id: "coalesced-0", text: text, fallback: fallback)
        let input = QuotePreviewInput(isLoaded: true, primary: ReplyPreviewSource(blocks: pair[0].blocks),
                                      fallback: fallback.flatMap { ReplyPreviewSource(text: $0) })
        let expectedWatchers = min(QuotePreviewPreparationService.watcherLimit,
                                  QuotePreviewPreparationService.watcherBytesLimit / (input.retainedByteCount + 512))
        let fixture = Fixture(items: pair)
        defer { fixture.stop() }
        let service = fixture.chat.quotePreviewPreparation
        let gate = QuotePreparationGate(id: "coalesced-0")
        service.normalizationGate = { await gate.arriveAndWait($0) }
        var owners: [ChatStore] = []
        defer { for owner in owners { owner.stopQuotePreviewPublication() } }
        try await self.gated(gate) {
            _ = fixture.chat.quote(for: pair[1])
            try await self.waitForEntry(gate)
            for index in 1...130 {
                let items = Self.pair(id: "coalesced-\(index)", text: text, fallback: fallback)
                let owner = ChatStore(sessionKey: "agent:main:quote-owner-\(index)", agentId: "main", gateway: fixture.gateway, headless: true)
                owner.quotePreviewPreparation = service
                owner.items = items
                owner.rebuild(itemsChanged: true)
                owners.append(owner)
                _ = owner.quote(for: items[1])
            }
            #expect(service.activeCount == 1 && service.pendingCount == 0, "Equal bounded source snapshots coalesce into one real worker")
            #expect(service.watcherCount == expectedWatchers)
            if largeInput {
                let shortInput = QuotePreviewInput(isLoaded: true, primary: ReplyPreviewSource(text: "Common coalesced opening"), fallback: nil)
                #expect(input.retainedByteCount > shortInput.retainedByteCount,
                        "The large-input control retains more actual source capacity than the short control")
                #expect(input.primary?.bytes.count == ReplyPreviewSource.byteLimit
                        && input.fallback?.bytes.count == ReplyPreviewSource.byteLimit,
                        "Both actual source captures contain the maximum admitted opening")
            }
            #expect(service.watcherByteCount == expectedWatchers * (input.retainedByteCount + 512),
                    "Actual watcher charges match retained primary and recorded fallback capacity")
            #expect(service.watcherByteCount <= QuotePreviewPreparationService.watcherBytesLimit)
            fixture.chat.stopQuotePreviewPublication()
            #expect(service.activeCount == 1, "Stopping one owner must not cancel a shared worker")
            await gate.release()
            await service.drain()
            let other = try #require(owners.first)
            let reply = try #require(other.items.last)
            #expect(other.quotePreviewRevision > 0)
            #expect(other.quote(for: reply)?.text?.hasPrefix("Common coalesced opening") == true)
            #expect(service.watcherCount == 0 && service.watcherByteCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(2))) func fullQuoteQueueDoesNotStarveActualSelectedReplyOrSendPreparation() async throws {
        let pairs = (0..<34).map { Self.pair(id: "independent-\($0)", text: "Independent meaningful source \($0)") }
        let fixture = Fixture(items: pairs.flatMap { $0 })
        defer { fixture.stop() }
        let gate = QuotePreparationGate(id: "independent-0")
        let service = fixture.chat.quotePreviewPreparation
        service.normalizationGate = { await gate.arriveAndWait($0) }
        fixture.chat.replyPreviewPreparation = ReplyPreviewPreparationService()
        try await self.gated(gate) {
            _ = fixture.chat.quote(for: pairs[0][1])
            try await self.waitForEntry(gate)
            for pair in pairs.dropFirst() { _ = fixture.chat.quote(for: pair[1]) }
            try #require(service.activeCount == 1 && service.pendingCount == 32)
            fixture.chat.selectReply(to: "independent-33", you: "You", agent: "Claw")
            await fixture.chat.waitForReplyPreviewPreparation()
            let selected = try #require(fixture.chat.replyTarget)
            #expect(selected.preview == "Independent meaningful source 33")
            let result = await fixture.chat.sendMessage("Quoted queue independence", replyTo: selected, includeLocation: false)
            #expect(result == .queued)
            #expect(fixture.chat.unsentEntries.contains { $0.text == "Quoted queue independence" && $0.replyToId == "independent-33" && !$0.isPreparingReply })
            #expect(service.activeCount == 1, "Interactive preparation finishes while incidental quote work is still held")
            await gate.release()
            await fixture.chat.waitForQuotePreviewPreparation()
        }
    }

    @Test func sourceAndFallbackChargeActualAllocationCapacity() async throws {
        let text = await Task.detached { String(repeating: "a", count: 2 * 1024 * 1024) }.value
        let primary = try #require(ReplyPreviewSource(text: text))
        let fallback = try #require(ReplyPreviewSource(text: text))
        let input = QuotePreviewInput(isLoaded: true, primary: primary, fallback: fallback)
        #expect(primary.bytes.count == 4096 && fallback.bytes.count == 4096)
        #expect(primary.retainedByteCount >= primary.bytes.capacity && fallback.retainedByteCount >= fallback.bytes.capacity)
        #expect(input.retainedByteCount >= primary.bytes.capacity + fallback.bytes.capacity)
        #expect(input.retainedByteCount <= QuotePreviewPreparationService.activeInputBytesLimit)
        let result = await Task.detached { input.prepare() }.value
        #expect(result.text == String(repeating: "a", count: 280))
    }

    @Test(.timeLimit(.minutes(2))) func stoppedCachingCannotRegisterOrPublishANewQuoteRequest() async throws {
        let pair = Self.pair(id: "stopped-caching-quote", text: "Stopped history quote opening")
        let fixture = Fixture(items: pair)
        defer { fixture.stop() }
        let service = fixture.chat.quotePreviewPreparation
        let gate = QuotePreparationGate(id: "stopped-caching-quote")
        service.normalizationGate = { await gate.arriveAndWait($0) }
        try await self.gated(gate) {
            _ = fixture.chat.quote(for: pair[1])
            try await self.waitForEntry(gate)
            try #require(service.activeCount == 1 && service.watcherCount == 1)
            fixture.chat.stopCaching()
            let stoppedRevision = fixture.chat.quotePreviewRevision
            #expect(service.watcherCount == 0 && service.deniedOwnerCount == 0)
            // This is a fresh real decoration request after session deletion, not merely
            // completion of the watcher removed by stopCaching.
            _ = fixture.chat.quote(for: pair[1])
            #expect(service.watcherCount == 0 && service.deniedOwnerCount == 0,
                    "A stopped history owner cannot register again through the actual quote API")
            await gate.release()
            await service.drain()
            #expect(fixture.chat.quotePreviewRevision == stoppedRevision,
                    "A post-stop quote request cannot publish a new renderer revision")
        }
    }

    @Test(.timeLimit(.minutes(2))) func deniedOwnersStayWeakBoundedAndCannotPublishAfterResetOrStop() async throws {
        let pairs = (0..<33).map { Self.pair(id: "denied-blocker-\($0)", text: "Distinct admission blocker \($0)") }
        let fixture = Fixture(items: pairs.flatMap { $0 })
        defer { fixture.stop() }
        let service = fixture.chat.quotePreviewPreparation
        let gate = QuotePreparationGate(id: "denied-blocker-0")
        service.normalizationGate = { await gate.arriveAndWait($0) }
        var owners: [ChatStore] = []
        defer { for owner in owners { owner.stopQuotePreviewPublication() } }
        func owner(_ index: Int) -> ChatStore {
            let chat = ChatStore(sessionKey: "agent:main:denied-owner-\(index)", agentId: "main", gateway: fixture.gateway, headless: true)
            chat.quotePreviewPreparation = service
            chat.items = Self.pair(id: "denied-target-\(index)", text: "Fresh denied owner opening")
            chat.rebuild(itemsChanged: true)
            return chat
        }
        try await self.gated(gate) {
            _ = fixture.chat.quote(for: pairs[0][1])
            try await self.waitForEntry(gate)
            for pair in pairs.dropFirst() { _ = fixture.chat.quote(for: pair[1]) }
            try #require(service.activeCount == 1 && service.pendingCount == 32)
            weak var weakOwner: ChatStore?
            do {
                let transient = owner(-1)
                weakOwner = transient
                _ = transient.quote(for: transient.items[1])
                #expect(service.deniedOwnerCount == 1)
            }
            #expect(weakOwner == nil, "Denied registration does not retain a history owner")
            for index in 0..<(QuotePreviewPreparationService.deniedOwnerLimit + 2) {
                let chat = owner(index)
                owners.append(chat)
                _ = chat.quote(for: chat.items[1])
            }
            try #require(service.deniedOwnerCount == QuotePreviewPreparationService.deniedOwnerLimit)
            #expect(service.deniedOwnerByteCount == QuotePreviewPreparationService.deniedOwnerBytesLimit)
            let reset = owners[0]
            let stopped = owners[1]
            await reset.reloadAfterHistoryChange()
            #expect(reset.items.isEmpty, "Actual history reset clears loaded authoritative messages")
            stopped.stopCaching()
            let resetRevision = reset.quotePreviewRevision
            let stoppedRevision = stopped.quotePreviewRevision
            let liveRevision = owners[2].quotePreviewRevision
            #expect(service.deniedOwnerCount == QuotePreviewPreparationService.deniedOwnerLimit - 2)
            _ = stopped.quote(for: stopped.items[1])
            #expect(service.deniedOwnerCount == QuotePreviewPreparationService.deniedOwnerLimit - 2,
                    "A denied stopped owner cannot rejoin the retry registry")
            await gate.release()
            await service.drain()
            #expect(reset.quotePreviewRevision == resetRevision && stopped.quotePreviewRevision == stoppedRevision)
            #expect(owners[2].quotePreviewRevision > liveRevision, "A live denied owner receives automatic retry readiness")
            #expect(owners.last?.quotePreviewRevision == 0, "Over-budget owners are not retained in an unbounded retry registry")
            #expect(service.deniedOwnerCount == 0 && service.deniedOwnerByteCount == 0)
            let live = owners[2]
            _ = live.quote(for: live.items[1])
            await service.drain()
            #expect(live.quote(for: live.items[1])?.text == "Fresh denied owner opening")
        }
    }

}
