import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Reply preview preparation")
struct ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func actualReplyTargetNeverNormalizesLargeSingleLineOnMain() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Reply test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "main", agentId: nil, gateway: gateway, headless: true)
        chat.replyPreviewPreparation = ReplyPreviewPreparationService()
        let id = UUID().uuidString
        var item = ChatItem(id: "local-id", role: .assistant,
                            blocks: [.text("Disk status " + String(repeating: "a", count: 200_000))])
        item.transcriptId = id
        ReplyPreviewDebugProbe.reset(tracking: id)
        defer { ReplyPreviewDebugProbe.unregister(tracking: id) }
        chat.items = [item]
        chat.rebuild(itemsChanged: true)
        let immediate = try #require(chat.replyTarget(for: id, you: "You", agent: "Claw"))
        #expect(immediate.messageId == id && immediate.senderLabel == "Claw" && immediate.isAssistant)
        await chat.waitForReplyPreviewPreparation()
        let target = try #require(chat.replyTarget(for: id, you: "You", agent: "Claw"))
        #expect(target.messageId == id)
        #expect(target.senderLabel == "Claw" && target.isAssistant)
        #expect(ReplyPreviewDebugProbe.stats(for: id).mainThreadNormalizations == 0,
                "The actual replyTarget path must not join or normalize the message text on Main")
        #expect(ReplyPreviewDebugProbe.stats(for: id).offMainNormalizations > 0,
                "The actual cold request must execute an instrumented worker")
        #expect(target.preview.count <= 280)
        #expect(target.preview.utf8.count <= 2_048)
        #expect(target.preview.hasPrefix("Disk status"))
    }

    @Test(.timeLimit(.minutes(2))) func exactIDProbePositiveControlRecordsMainNormalization() {
        let id = UUID().uuidString
        ReplyPreviewDebugProbe.reset(tracking: id)
        defer { ReplyPreviewDebugProbe.unregister(tracking: id) }
        ReplyPreviewDebugProbe.recordNormalization(for: id)
        #expect(ReplyPreviewDebugProbe.stats(for: id).mainThreadNormalizations == 1)
        #expect(ReplyPreviewDebugProbe.stats(for: id).offMainNormalizations == 0)
    }

    @Test(.timeLimit(.minutes(2))) func replyMetadataPreservesUserSenderAndTranscriptIdentity() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Reply metadata", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "main", agentId: nil, gateway: gateway, headless: true)
        var item = ChatItem(id: "local-user", role: .user, blocks: [.text("  A short question  ")])
        item.transcriptId = "user-transcript"
        chat.items = [item]
        chat.rebuild(itemsChanged: true)
        let immediate = try #require(chat.replyTarget(for: "user-transcript", you: "You", agent: "Claw"))
        #expect(immediate.messageId == "user-transcript" && immediate.senderLabel == "You" && !immediate.isAssistant)
        await chat.waitForReplyPreviewPreparation()
        let target = try #require(chat.replyTarget(for: "user-transcript", you: "You", agent: "Claw"))
        #expect(target.messageId == "user-transcript" && target.senderLabel == "You" && !target.isAssistant)
        #expect(target.preview == "A short question")
        #expect(chat.replyTarget(for: "local-user", you: "You", agent: "Claw") == nil)
        #expect(chat.replyTarget(for: "missing", you: "You", agent: "Claw") == nil)
    }
}

private actor ReplyPreparationGate {
    private var entered = 0
    private var open = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []

    func arriveAndWait(_ id: String) async {
        self.entered += 1
        let ready = self.arrivals.filter { $0.0 <= self.entered }
        self.arrivals.removeAll { $0.0 <= self.entered }
        for waiter in ready { waiter.1.resume() }
        guard !self.open else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || self.open { continuation.resume() }
                else { self.held.append(continuation) }
            }
        } onCancel: { Task { await self.releaseAll() } }
    }

    func waitForEntered(_ count: Int) async {
        guard self.entered < count, !self.open else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || self.open { continuation.resume() }
                else { self.arrivals.append((count, continuation)) }
            }
        } onCancel: { Task { await self.releaseAll() } }
    }

    func releaseAll() {
        self.open = true
        let held = self.held
        let arrivals = self.arrivals
        self.held = []
        self.arrivals = []
        for waiter in held { waiter.resume() }
        for waiter in arrivals { waiter.1.resume() }
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func cheapActiveInputNeverSubsidizesPendingMultiblockCapacity() async throws {
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let service = ReplyPreviewPreparationService()
        service.normalizationGate = { await gate.arriveAndWait($0) }
        defer { service.cancel() }
        let active = try #require(ReplyPreviewSource(text: "a"))
        _ = try #require(service.request(active, messageID: "cheap-active"))
        await gate.waitForEntered(1)
        try #require(service.activeCount == 1 && service.pendingByteCount == 0)

        var admittedBytes = 0
        for number in 0..<ReplyPreviewPreparationService.pendingLimit {
            let opening = "pending-\(number) "
            let blocks: [ContentBlock] = [.text(opening + String(repeating: "p", count: 300 - opening.utf8.count))]
                + Array(repeating: .text(String(repeating: "q", count: 300)), count: 15)
            let source = try #require(ReplyPreviewSource(blocks: blocks))
            try #require(source.bytes.count == ReplyPreviewSource.byteLimit)
            let cost = source.retainedByteCount // Actual retained capacity, never an allocator-size assumption.
            try #require(cost > ReplyPreviewSource.byteLimit + 512,
                         "Multiblock fixture must retain excess capacity; measured cost: \(cost)")
            try #require(cost <= ReplyPreviewPreparationService.activeInputBytesLimit)
            if cost > ReplyPreviewPreparationService.pendingBytesLimit - admittedBytes { break }
            _ = try #require(service.request(source, messageID: "multiblock-\(number)"))
            admittedBytes += cost
            #expect(service.pendingByteCount == admittedBytes)
            #expect(service.pendingByteCount <= ReplyPreviewPreparationService.pendingBytesLimit)
        }

        // Uniform chunks can jump past both the correct budget and the old fixed slack. Fill
        // the measured remaining gap, then deliberately cross it by an amount the old guard
        // could afford. Every cost below comes from the source's actual retained capacity.
        func singleBlock(_ label: String, bytes: Int) throws -> ReplyPreviewSource {
            try #require(bytes >= label.utf8.count)
            return try #require(ReplyPreviewSource(text: label + String(repeating: "r", count: bytes - label.utf8.count)))
        }
        let full = try singleBlock("gap-fill ", bytes: ReplyPreviewSource.byteLimit)
        if full.retainedByteCount <= ReplyPreviewPreparationService.pendingBytesLimit - admittedBytes {
            try #require(service.pendingCount < ReplyPreviewPreparationService.pendingLimit - 1)
            _ = try #require(service.request(full, messageID: "gap-fill"))
            admittedBytes += full.retainedByteCount
            #expect(service.pendingByteCount == admittedBytes)
            #expect(service.pendingByteCount <= ReplyPreviewPreparationService.pendingBytesLimit)
        }

        let remaining = ReplyPreviewPreparationService.pendingBytesLimit - admittedBytes
        let oldSlack = ReplyPreviewSource.byteLimit + 512 - active.retainedByteCount
        try #require(oldSlack > 0 && service.pendingCount < ReplyPreviewPreparationService.pendingLimit)
        var crossing: ReplyPreviewSource?
        for byteCount in stride(from: 16, through: ReplyPreviewSource.byteLimit, by: 16) {
            let candidate = try singleBlock("cross-budget ", bytes: byteCount)
            if candidate.retainedByteCount > remaining,
               candidate.retainedByteCount <= remaining + oldSlack {
                crossing = candidate
                break
            }
        }
        let diagnostic = "active=\(active.retainedByteCount), pending=\(admittedBytes), remaining=\(remaining), oldSlack=\(oldSlack), count=\(service.pendingCount)"
        let crossingSource = try #require(crossing, "No measured source crosses only the correct budget: \(diagnostic)")
        let before = service.pendingByteCount
        let rejected = service.request(crossingSource, messageID: "cross-budget") == nil
        #expect(rejected, "Byte-overload must reject candidate cost=\(crossingSource.retainedByteCount); \(diagnostic)")
        #expect(service.pendingByteCount <= ReplyPreviewPreparationService.pendingBytesLimit,
                "Cheap active work cannot subsidize pending bytes; candidate cost=\(crossingSource.retainedByteCount); \(diagnostic)")
        if rejected { #expect(service.pendingByteCount == before) }
        await gate.releaseAll()
        await service.drain()
        #expect(service.activeCount == 0 && service.pendingCount == 0 && service.pendingByteCount == 0)
    }

    private func setup(_ items: [ChatItem], defaults: UserDefaults) -> (ChatStore, GatewayStore) {
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Reply lifecycle", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        let chat = ChatStore(sessionKey: "main", agentId: nil, gateway: gateway, headless: true)
        chat.items = items
        chat.rebuild(itemsChanged: true)
        return (chat, gateway)
    }

    private func source(_ id: String, _ text: String, role: ChatRole = .assistant) -> ChatItem {
        var item = ChatItem(id: "local-\(id)", role: role, blocks: [.text(text)])
        item.transcriptId = id
        return item
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["different", "same", "cancel"])
    func delayedPreviewRespectsCurrentSelectionIdentity(_ action: String) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chat, gateway) = self.setup([self.source("a", "Original A"), self.source("b", "New B")], defaults: scratch.defaults)
        defer { gateway.stop() }
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let service = ReplyPreviewPreparationService()
        service.normalizationGate = { await gate.arriveAndWait($0) }
        chat.replyPreviewPreparation = service
        chat.selectReply(to: "a", you: "You", agent: "Claw")
        let original = try #require(chat.replyTarget)
        #expect(original.messageId == "a" && original.preview.isEmpty)
        await gate.waitForEntered(1)
        if action == "different" { chat.selectReply(to: "b", you: "You", agent: "Claw") }
        if action == "same" { chat.selectReply(to: "a", you: "You", agent: "Claw") }
        if action == "cancel" { chat.replyTarget = nil }
        let currentSelection = chat.replyTarget?.selectionID
        if action != "cancel" { #expect(currentSelection != original.selectionID) }
        await gate.releaseAll()
        await chat.waitForReplyPreviewPreparation()
        if action == "cancel" {
            #expect(chat.replyTarget == nil)
        } else {
            #expect(chat.replyTarget?.selectionID == currentSelection)
            #expect(chat.replyTarget?.messageId == (action == "different" ? "b" : "a"))
            #expect(chat.replyTarget?.preview == (action == "different" ? "New B" : "Original A"))
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["multiblock", "unicode", "unicode-boundary", "literal-replacement", "literal-replacement-at-cap", "giant-grapheme", "directive", "image", "attachment"])
    func preparedPreviewPreservesBoundedTextAndMediaSemantics(_ kind: String) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        var item = self.source(UUID().uuidString, "")
        let expected: String?
        switch kind {
        case "multiblock":
            item.blocks = [.text("  # One **two**\n"), .thinking("Hidden reasoning"), .text(" Three   four ")]
            expected = "One two Three four"
        case "unicode":
            item.blocks = [.text(String(repeating: "👨‍👩‍👧‍👦", count: 400))]
            expected = nil
        case "unicode-boundary":
            item.blocks = [.text(String(repeating: " ", count: 4_089) + "éééé")]
            expected = "ééé"
        case "literal-replacement":
            item.blocks = [.text("Literal \u{FFFD}")]
            expected = "Literal \u{FFFD}"
        case "literal-replacement-at-cap":
            let capPrefix = "a" + String(repeating: "\u{0301}", count: 1_022) + "\u{FFFD}"
            #expect(capPrefix.utf8.count == 2_048)
            item.blocks = [.text(capPrefix + "x")]
            expected = capPrefix
        case "giant-grapheme":
            item.blocks = [.text("a" + String(repeating: "\u{0301}", count: 10_000))]
            expected = nil
        case "directive":
            item.blocks = [.text("Here you go\nMEDIA:/tmp/photo.png\nEnjoy")]
            expected = "Here you go Enjoy"
        case "image":
            item.blocks = [.image(ImageRef(artifactId: "image", base64: nil, url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil))]
            expected = "Image"
        default:
            item.blocks = [.file(FileRef(name: "notes.txt", mimeType: "text/plain"))]
            expected = "Attachment"
        }
        let (chat, gateway) = self.setup([item], defaults: scratch.defaults)
        defer { gateway.stop() }
        let id = try #require(item.transcriptId)
        _ = chat.replyTarget(for: id, you: "You", agent: "Claw")
        await chat.waitForReplyPreviewPreparation()
        let target = try #require(chat.replyTarget(for: id, you: "You", agent: "Claw"))
        #expect(target.preview.count <= 280)
        #expect(target.preview.utf8.count <= 2_048)
        if !kind.hasPrefix("literal-replacement") {
            #expect(!target.preview.contains("\u{FFFD}"), "A byte boundary must not publish malformed UTF-8 replacement text")
        }
        if let expected { #expect(target.preview == expected) }
        if kind == "unicode" { #expect(target.preview.hasPrefix("👨‍👩‍👧‍👦")) }
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func admittedPendingSourcesAndCompletedCacheStayBounded() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let sources = (0..<140).map { self.source("cache-\($0)", "Opening \($0) " + String(repeating: "x", count: 8_000)) }
        let (chat, gateway) = self.setup(sources, defaults: scratch.defaults)
        defer { gateway.stop() }
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let service = ReplyPreviewPreparationService()
        service.normalizationGate = { await gate.arriveAndWait($0) }
        chat.replyPreviewPreparation = service
        _ = chat.replyTarget(for: "cache-0", you: "You", agent: "Claw")
        await gate.waitForEntered(1)
        for number in 1..<40 {
            let target = chat.replyTarget(for: "cache-\(number)", you: "You", agent: "Claw")
            #expect(target?.messageId == "cache-\(number)")
            #expect(service.activeCount <= 1 && service.pendingCount <= 32)
            #expect(service.pendingByteCount <= ReplyPreviewPreparationService.pendingBytesLimit + ReplyPreviewSource.byteLimit + 512)
        }
        await gate.releaseAll()
        await chat.waitForReplyPreviewPreparation()
        for start in stride(from: 0, to: 140, by: 28) {
            for number in start..<min(start + 28, 140) {
                _ = chat.replyTarget(for: "cache-\(number)", you: "You", agent: "Claw")
            }
            await chat.waitForReplyPreviewPreparation()
            #expect(service.cachedCount <= ReplyPreviewPreparationService.cacheLimit)
            #expect(service.cachedByteCount <= ReplyPreviewPreparationService.cacheBytesLimit)
        }
        #expect(service.activeCount == 0 && service.pendingCount == 0 && service.pendingByteCount == 0)
        #expect(service.cachedCount > 0)
        let last = chat.replyTarget(for: "cache-139", you: "You", agent: "Claw")
        #expect(last?.preview.hasPrefix("Opening 139") == true)
    }
}

@MainActor
private final class ReplyReservationEvents {
    private(set) var keys: [String] = []
    private(set) var completed: Set<String> = []
    private var waits: [(UUID, Int, String?, CheckedContinuation<Void, Never>)] = []

    func reserved(_ key: String) { self.keys.append(key); self.resumeReady() }
    func finished(_ name: String) { self.completed.insert(name); self.resumeReady() }
    private func resumeReady() {
        let ready = self.waits.filter { self.keys.count >= $0.1 && ($0.2 == nil || self.completed.contains($0.2!)) }
        self.waits.removeAll { candidate in ready.contains { $0.0 == candidate.0 } }
        for waiter in ready { waiter.3.resume() }
    }
    func wait(count: Int = 0, completion: String? = nil) async {
        if self.keys.count >= count && (completion == nil || self.completed.contains(completion!)) { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { self.waits.append((id, count, completion, continuation)) }
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = self.waits.firstIndex(where: { $0.0 == id }) else { return }
        self.waits.remove(at: index).3.resume()
    }
    func cancelAll() {
        let waits = self.waits
        self.waits = []
        for waiter in waits { waiter.3.resume() }
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2)), arguments: ["ready", "delete", "cancel"])
    func coldReplyReservationHoldsLaterSendAndPersistenceUntilItsCapturedQuoteIsReady(_ releaseMode: String) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chat, gateway) = self.setup([self.source("original", "Original captured quote"), self.source("new-selection", "New selection quote")], defaults: scratch.defaults)
        defer { gateway.stop() }
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let service = ReplyPreviewPreparationService()
        service.normalizationGate = { await gate.arriveAndWait($0) }
        chat.replyPreviewPreparation = service
        let events = ReplyReservationEvents()
        defer { events.cancelAll(); chat.replyPreparationDidReserve = nil }
        chat.replyPreparationDidReserve = { events.reserved($0) }
        chat.selectReply(to: "original", you: "You", agent: "Claw")
        let captured = try #require(chat.replyTarget)
        let deleteFirst = releaseMode != "ready"
        let sendA = Task { @MainActor in
            let result = await chat.sendMessage("A", replyTo: captured)
            events.finished("A")
            return result
        }
        defer { sendA.cancel() }
        await events.wait(count: 1)
        await gate.waitForEntered(1)
        let sendB = Task { @MainActor in
            let result = await chat.sendMessage("B")
            events.finished("B")
            return result
        }
        defer { sendB.cancel() }
        await events.wait(count: 2)
        let keyA = try #require(events.keys.first)
        let keyB = try #require(events.keys.last)
        #expect(chat.items.filter(\.isPending).map(\.plainText) == ["A", "B"])
        #expect(!events.completed.contains("A") && !events.completed.contains("B"))
        #expect(gateway.outbox.nextToSend(sessionKey: chat.sessionKey) == nil)
        #expect(!gateway.outbox.persistable.entries.contains { $0.id == keyA || $0.id == keyB })
        let other = ChatStore(sessionKey: "other", agentId: nil, gateway: gateway, headless: true)
        #expect(await other.sendMessage("C") == .queued, "A preparing quote blocks its own session only")
        #expect(gateway.outbox.persistable.entries.contains { $0.sessionKey == "other" && $0.text == "C" })

        chat.selectReply(to: "new-selection", you: "You", agent: "Claw")
        let newerSelection = chat.replyTarget?.selectionID
        if deleteFirst { chat.replyTarget = nil }
        if deleteFirst {
            if releaseMode == "cancel" { sendA.cancel() }
            else { chat.discardUnsent(keyA) }
            await events.wait(completion: "B")
            await events.wait(completion: "A")
            if case .failed = await sendA.value {} else { Issue.record("Removed or canceled preparing reply A must fail rather than be accepted") }
            #expect(gateway.outbox.entry(id: keyA) == nil)
        }
        await gate.releaseAll()
        await chat.waitForReplyPreviewPreparation()
        _ = await sendA.value
        #expect(await sendB.value == .queued)
        if deleteFirst {
            #expect(chat.replyTarget == nil, "Finishing captured A must not restore a canceled UI selection")
        } else {
            #expect(chat.replyTarget?.selectionID == newerSelection, "Accepting captured A must not clear a newer reply selection")
            #expect(chat.replyTarget?.messageId == "new-selection")
            #expect(chat.replyTarget?.preview == "New selection quote")
        }
        if deleteFirst {
            #expect(gateway.outbox.entry(id: keyA) == nil)
            #expect(!chat.items.contains { $0.idempotencyKey == keyA })
        } else {
            let entryA = try #require(gateway.outbox.entry(id: keyA))
            #expect(entryA.replyToId == "original" && entryA.replyPreview?.text == "Original captured quote")
            #expect(entryA.id == keyA && entryA.idempotencyKey == keyA)
            #expect(chat.items.first { $0.idempotencyKey == keyA }?.replyToPreview?.text == "Original captured quote")
            #expect(gateway.outbox.entries(for: chat.sessionKey).map(\.id) == [keyA, keyB])
            let saved = try JSONEncoder().encode(gateway.outbox.persistable)
            var restored = try JSONDecoder().decode(Outbox.self, from: saved)
            #expect(restored.entry(id: keyA)?.replyPreview == entryA.replyPreview)
            #expect(restored.entries(for: chat.sessionKey).map(\.id) == [keyA, keyB])
            restored.rekey(id: keyA, to: "fallback-key")
            #expect(restored.entries(for: chat.sessionKey).map(\.id) == ["fallback-key", keyB])
            #expect(restored.entry(id: "fallback-key")?.replyPreview == entryA.replyPreview)
            #expect(restored.entry(id: "fallback-key")?.replyToId == "original")
        }
        #expect(gateway.outbox.persistable.entries.contains { $0.id == keyB })
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2)), arguments: ["edit", "remove", "stop"])
    func heldPreviewCannotPublishStaleHistoryOrStoppedLifecycle(_ change: String) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chat, gateway) = self.setup([self.source("edited", "Old history text")], defaults: scratch.defaults)
        defer { gateway.stop() }
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let service = ReplyPreviewPreparationService()
        service.normalizationGate = { await gate.arriveAndWait($0) }
        chat.replyPreviewPreparation = service
        chat.selectReply(to: "edited", you: "You", agent: "Claw")
        let selection = try #require(chat.replyTarget?.selectionID)
        await gate.waitForEntered(1)
        if change == "edit" {
            chat.items = [self.source("edited", "Edited history text")]
            chat.rebuild(itemsChanged: true)
        } else if change == "remove" {
            chat.items = []
            chat.rebuild(itemsChanged: true)
        } else {
            chat.stopReplyPreviewPublication()
        }
        await gate.releaseAll()
        await chat.waitForReplyPreviewPreparation()
        if change == "edit" {
            #expect(chat.replyTarget?.selectionID == selection)
            #expect(chat.replyTarget?.preview == "Edited history text")
        } else {
            #expect(chat.replyTarget == nil)
        }
    }

    @Test(.timeLimit(.minutes(2))) func sourceCaptureInspectsOnlyItsBoundedOpeningAndTagBudget() {
        let text = String(repeating: "x", count: 100_000)
        let source = ReplyPreviewSource(blocks: [.text(text)])
        #expect(source?.bytes.count == 4_096)
        let beyondBudget = ReplyPreviewSource(blocks: Array(repeating: .thinking("Ignored"), count: 64) + [.text("Must not enter preview")])
        #expect(beyondBudget == nil, "A source with no known opening inside the tag budget must be unavailable")
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func unavailableSourceFailsWithoutAnOptimisticEmptyQuote() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chat, gateway) = self.setup([], defaults: scratch.defaults)
        defer { gateway.stop() }
        let unavailable = ReplyTarget(messageId: "missing", senderLabel: "Claw", preview: "", isAssistant: true)
        let result = await chat.sendMessage("Cannot quote missing source", replyTo: unavailable)
        if case .failed = result {} else { Issue.record("Missing source must fail explicitly: \(result)") }
        #expect(chat.items.isEmpty && gateway.outbox.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func legacyCapturedTextStillPreparesABoundedPersistableQuote() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chat, gateway) = self.setup([], defaults: scratch.defaults)
        defer { gateway.stop() }
        chat.replyPreviewPreparation = ReplyPreviewPreparationService()
        let id = UUID().uuidString
        ReplyPreviewDebugProbe.reset(tracking: id)
        defer { ReplyPreviewDebugProbe.unregister(tracking: id) }
        let legacy = ReplyTarget(messageId: id, senderLabel: "Claw",
                                 preview: "Legacy saved quote " + String(repeating: "x", count: 200_000), isAssistant: true)
        #expect(await chat.sendMessage("Reply after restore", replyTo: legacy) == .queued)
        let entry = try #require(gateway.outbox.entries.first)
        #expect(entry.replyToId == id)
        #expect(entry.replyPreview?.text.hasPrefix("Legacy saved quote") == true)
        #expect((entry.replyPreview?.text.count ?? Int.max) <= 280)
        #expect((entry.replyPreview?.text.utf8.count ?? Int.max) <= 2_048)
        #expect(ReplyPreviewDebugProbe.stats(for: id).mainThreadNormalizations == 0)
        #expect(ReplyPreviewDebugProbe.stats(for: id).offMainNormalizations > 0)
        let restored = try JSONDecoder().decode(Outbox.self, from: JSONEncoder().encode(gateway.outbox.persistable))
        #expect(restored.entries.first?.replyPreview == entry.replyPreview)
        #expect(restored.entries.first?.idempotencyKey == entry.idempotencyKey)
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func canceledReadinessWaitDoesNotCancelPinnedPreparationOrHangCleanup() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chat, gateway) = self.setup([self.source("cancel-wait", "Prepared after waiter cancellation")], defaults: scratch.defaults)
        defer { gateway.stop() }
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let service = ReplyPreviewPreparationService()
        service.normalizationGate = { await gate.arriveAndWait($0) }
        chat.replyPreviewPreparation = service
        _ = chat.replyTarget(for: "cancel-wait", you: "You", agent: "Claw")
        await gate.waitForEntered(1)
        let wait = Task { await chat.waitForReplyPreviewPreparation() }
        wait.cancel()
        await wait.value
        #expect(service.activeCount == 1)
        await gate.releaseAll()
        await chat.waitForReplyPreviewPreparation()
        #expect(chat.replyTarget(for: "cancel-wait", you: "You", agent: "Claw")?.preview == "Prepared after waiter cancellation")
        #expect(service.activeCount == 0 && service.pendingByteCount == 0)
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func twoChatsShareOnePreparationBudgetAndStoppingOneOwnerPreservesAnotherSend() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chatA, gatewayA) = self.setup([self.source("owner-a", "Owner A")], defaults: scratch.defaults)
        let sourcesB = (0..<40).map { self.source("owner-b-\($0)", "Owner B \($0) " + String(repeating: "b", count: 8_000)) }
        let (chatB, gatewayB) = self.setup(sourcesB, defaults: scratch.defaults)
        defer { gatewayA.stop(); gatewayB.stop() }
        #expect(chatA.replyPreviewPreparation === chatB.replyPreviewPreparation,
                "Production chat stores must share the same globally bounded service")
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let shared = ReplyPreviewPreparationService()
        shared.normalizationGate = { await gate.arriveAndWait($0) }
        chatA.replyPreviewPreparation = shared
        chatB.replyPreviewPreparation = shared
        let events = ReplyReservationEvents()
        defer { events.cancelAll(); chatB.replyPreparationDidReserve = nil }
        chatB.replyPreparationDidReserve = { events.reserved($0) }
        let captured = try #require(chatB.replyTarget(for: "owner-b-0", you: "You", agent: "Claw"))
        let send = Task { await chatB.sendMessage("Pinned owner B", replyTo: captured) }
        defer { send.cancel() }
        await events.wait(count: 1)
        await gate.waitForEntered(1)
        chatA.selectReply(to: "owner-a", you: "You", agent: "Claw")
        for number in 1..<40 {
            _ = chatB.replyTarget(for: "owner-b-\(number)", you: "You", agent: "Claw")
            #expect(shared.activeCount <= 1 && shared.pendingCount <= 32)
            #expect(shared.pendingByteCount <= ReplyPreviewPreparationService.pendingBytesLimit + ReplyPreviewSource.byteLimit + 512)
        }
        gatewayA.stop()
        #expect(gatewayB.outbox.entries.first?.replyToId == "owner-b-0")
        #expect(shared.activeCount == 1)
        await gate.releaseAll()
        #expect(await send.value == .queued)
        await shared.drain()
        #expect(gatewayB.outbox.entries.first?.replyPreview?.text.hasPrefix("Owner B 0") == true)
        #expect(shared.activeCount == 0 && shared.pendingCount == 0 && shared.pendingByteCount == 0)
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["unavailable", "overflow"])
    func sourceRevalidationNeverRetainsAnOldQuoteWhenNewPreparationCannotBeAdmitted(_ failure: String) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let originals = [self.source("changing", "Old cached quote")] + (0..<33).map {
            self.source("blocker-\($0)", "Blocker \($0) " + String(repeating: "x", count: 8_000))
        }
        let (chat, gateway) = self.setup(originals, defaults: scratch.defaults)
        defer { gateway.stop() }
        let service = ReplyPreviewPreparationService()
        chat.replyPreviewPreparation = service
        chat.selectReply(to: "changing", you: "You", agent: "Claw")
        await chat.waitForReplyPreviewPreparation()
        #expect(chat.replyTarget?.preview == "Old cached quote")
        let selection = try #require(chat.replyTarget?.selectionID)
        let gate = ReplyPreparationGate()
        defer { Task { await gate.releaseAll() } }
        service.normalizationGate = { await gate.arriveAndWait($0) }
        if failure == "overflow" {
            // Distinct uncached openings fill this service's one active + 32 pending slots.
            for number in 0..<33 {
                let blocker = self.source("fresh-\(number)", "Fresh blocker \(number)")
                chat.items.append(blocker)
            }
            chat.rebuild(itemsChanged: true)
            _ = chat.replyTarget(for: "fresh-0", you: "You", agent: "Claw")
            await gate.waitForEntered(1)
            for number in 1..<33 { _ = chat.replyTarget(for: "fresh-\(number)", you: "You", agent: "Claw") }
            try #require(service.activeCount == 1 && service.pendingCount == 32,
                         "Short distinct openings must fill the count budget before testing rejected current-source preparation")
        }
        var replacement = self.source("changing", "New authoritative opening")
        if failure == "unavailable" {
            // No known text or media lies within the 64-tag opening. The visible message
            // exists but its source is unavailable under the bounded capture policy.
            replacement.blocks = Array(repeating: .thinking("Uninspected"), count: 64) + [.text("New text beyond opening")]
            #expect(ReplyPreviewSource(blocks: replacement.blocks) == nil)
        }
        chat.items[0] = replacement
        chat.rebuild(itemsChanged: true)
        let current = try #require(chat.replyTarget)
        #expect(current.selectionID == selection && current.preview.isEmpty)
        if failure == "unavailable" {
            #expect(current.previewUnavailable && current.previewSource == nil)
        } else {
            #expect(current.previewSource == ReplyPreviewSource(blocks: replacement.blocks))
        }
        let outcome = await chat.sendMessage("Must not quote old text", replyTo: current)
        if case .failed = outcome {} else { Issue.record("Unavailable or rejected current preparation must fail, not accept stale text: \(outcome)") }
        #expect(gateway.outbox.isEmpty)
        #expect(!chat.items.contains { $0.isPending && $0.replyToPreview?.text.contains("Old cached quote") == true })
        await gate.releaseAll()
        await service.drain()
    }
}

extension ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func truncatedWhitespaceOpeningIsUnavailableRatherThanAnAttachmentQuote() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (chat, gateway) = self.setup([self.source("whitespace-opening", String(repeating: " ", count: 5_000) + "Real text beyond bounded opening")], defaults: scratch.defaults)
        defer { gateway.stop() }
        chat.replyPreviewPreparation = ReplyPreviewPreparationService()
        chat.selectReply(to: "whitespace-opening", you: "You", agent: "Claw")
        await chat.waitForReplyPreviewPreparation()
        let current = try #require(chat.replyTarget)
        #expect(current.preview.isEmpty && current.previewUnavailable)
        let outcome = await chat.sendMessage("Must not quote Attachment", replyTo: current)
        if case .failed = outcome {} else { Issue.record("An unavailable truncated opening must not be accepted as Attachment") }
        #expect(gateway.outbox.isEmpty && !chat.items.contains(where: \.isPending))
    }
}
