import Foundation
import Testing
import Observation
import Synchronization
@testable import PincerKit

@MainActor
@Suite("Reply Last availability", .serialized)
struct ReplyLastAvailabilityTests {
    private func item(_ id: String, role: ChatRole = .assistant, blocks: [ContentBlock]) -> ChatItem {
        var item = ChatItem(id: id, role: role, blocks: blocks)
        item.transcriptId = id
        item.timestamp = Date(timeIntervalSince1970: 1)
        return item
    }
    @Test(.timeLimit(.minutes(2))) func actualAvailabilityDoesNotNormalizeLargeMultiblockTextOnMain() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "reply-last-causal", agentId: nil, gateway: gateway, headless: true)
        chat.replyLastPreparation = ReplyLastAvailabilityPreparation()
        let id = UUID().uuidString
        let blocks = await Task.detached { [ContentBlock.text(""), .text(String(repeating: " ", count: 1_048_576)),
                                           .text(String(repeating: "x", count: 1_048_576))] }.value
        chat.items = [self.item(id, blocks: blocks)]
        ReplyLastAvailabilityDebugProbe.reset(tracking: id)
        defer { ReplyLastAvailabilityDebugProbe.unregister(tracking: id) }
        #expect(chat.latestReplyableId == nil, "cold unknown cannot choose an older target")
        await chat.replyLastPreparation.waitUntilIdle()
        #expect(chat.latestReplyableId == id, "content after a giant whitespace block remains eligible")
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: id).mainNormalizations == 0,
                "actual Reply Last validation must not join and trim 2 MiB on Main")
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: id).offMainNormalizations > 0)
    }
    @Test(.timeLimit(.minutes(2))) func actualEligibilityPreservesEmptyWhitespaceUserAndToolSemantics() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "reply-last-controls", agentId: nil, gateway: gateway, headless: true)
        chat.replyLastPreparation = ReplyLastAvailabilityPreparation()
        let base = self.item("base", blocks: [.text("Answer")])
        for blocks: [ContentBlock] in [[], [.text("")], [.text(" \n\t")], [.toolCall(id: "tool", name: "read", arguments: nil)],
            [.image(ImageRef(artifactId: nil, base64: nil, url: "https://example.com/image.png", mimeType: "image/png", alt: nil, width: nil, height: nil))]] {
            chat.items = [base, self.item("empty", blocks: blocks)]
            await chat.replyLastPreparation.waitUntilIdle()
            #expect(chat.latestReplyableId == "base")
        }
        chat.items = [base, self.item("user", role: .user, blocks: [])]
        #expect(chat.latestReplyableId == "user", "committed users remain replyable without text")
        chat.items = [base, self.item("tool", role: .toolResult, blocks: [.text("Result")])]
        await chat.replyLastPreparation.waitUntilIdle()
        #expect(chat.latestReplyableId == "base")
        chat.items = []
        #expect(chat.latestReplyableId == nil)
    }
    @Test func observerIsBoundedAndUnregisteredIDsStaySilent() async {
        let ids = (0..<20).map { "probe-\(UUID().uuidString)-\($0)" }
        defer { for id in ids { ReplyLastAvailabilityDebugProbe.unregister(tracking: id) } }
        for id in ids { ReplyLastAvailabilityDebugProbe.reset(tracking: id) }
        #expect(ReplyLastAvailabilityDebugProbe.trackedCount <= 16)
        let tracked = ids[0]
        await Task.detached { ReplyLastAvailabilityDebugProbe.record(tracking: tracked) }.value
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: tracked).offMainNormalizations == 1)
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: tracked).mainNormalizations == 0)
        let absent = UUID().uuidString
        ReplyLastAvailabilityDebugProbe.record(tracking: absent)
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: absent).mainNormalizations == 0)
    }
    @Test(.timeLimit(.minutes(2))) func exactUnicodeAndAllBlocksAreScannedWithoutPreviewLimits() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "unicode", agentId: nil, gateway: gateway, headless: true)
        chat.replyLastPreparation = ReplyLastAvailabilityPreparation()
        let samples = await Task.detached { () -> [[ContentBlock]] in
            let foreign = NSString(string: String(repeating: "\u{2003}", count: 5000) + "Answer") as String
            return [
                [.text(String(repeating: " ", count: 2047) + "😀")],
                [.text("a" + String(repeating: "\u{301}", count: 10000))],
                [.text(foreign)],
                Array(repeating: .text(" \n\u{2003}"), count: 80) + [.text("Answer")],
                Array(repeating: .text("\u{2003}\u{2028}\u{85}"), count: 80),
                [.text("\u{FFFD}")]
            ]
        }.value
        for (index, blocks) in samples.enumerated() {
            let id = "unicode-\(index)"
            chat.items = [self.item("older", role: .user, blocks: []), self.item(id, blocks: blocks)]
            #expect(chat.latestReplyableId == nil, "unknown assistant blocks an older user")
            await chat.replyLastPreparation.waitUntilIdle()
            #expect(chat.latestReplyableId == (index == 4 ? "older" : id))
        }
        #expect(chat.replyLastPreparation.peakChunkBytes <= ReplyLastAvailabilityPreparation.inputByteLimit)
    }

    private actor Gate {
        var open = false
        var arrivals = 0
        func hold() async {
            self.arrivals += 1
            let deadline = ContinuousClock.now + .seconds(120)
            while !self.open && !Task.isCancelled && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        func release() { self.open = true }
        func arrived() -> Bool { self.arrivals > 0 }
    }

    @Test(.timeLimit(.minutes(2))) func staleHeldChunksCannotPublishAfterEditRemovalOrReset() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "stale", agentId: nil, gateway: gateway, headless: true)
        for mode in 0..<3 {
            let service = ReplyLastAvailabilityPreparation()
            let gate = Gate()
            service.chunkGate = { await gate.hold() }
            chat.replyLastPreparation = service
            defer { Task { await gate.release() } }
            chat.items = [self.item("same", blocks: [.text("old")])]
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await gate.arrived()) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await gate.arrived(), "actual worker reaches its held chunk")
            switch mode {
            case 0: chat.items = [self.item("same", blocks: [.text(" ")])]
            case 1: chat.items = [self.item("replacement", role: .user, blocks: [])]
            default: chat.items = []
            }
            #expect(service.activeCount == 1, "cancellation cannot release actual active ownership")
            await gate.release()
            await service.waitUntilIdle()
            #expect(chat.latestReplyableId == (mode == 1 ? "replacement" : nil))
            #expect(chat.replyLastPreparedRevision == chat.contentRevision)
        }
    }

    @Test(.timeLimit(.minutes(2))) func globalPendingAdmissionIsBoundedAndRejectedStoreRetries() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let service = ReplyLastAvailabilityPreparation()
        let gate = Gate()
        service.chunkGate = { await gate.hold() }
        defer { Task { await gate.release() } }
        let stores = (0..<35).map { index in
            let chat = ChatStore(sessionKey: "queue-\(index)", agentId: nil, gateway: gateway, headless: true)
            chat.replyLastPreparation = service
            chat.items = [self.item("answer-\(index)", blocks: [.text("Answer")])]
            return chat
        }
        #expect(service.activeCount == 1 && service.pendingCount == 32)
        #expect(stores.last?.latestReplyableId == nil)
        await gate.release()
        await service.waitUntilIdle()
        let rejected = try #require(stores.last)
        #expect(rejected.latestReplyableId == nil, "a freed slot starts exact preparation without guessing")
        await service.waitUntilIdle()
        #expect(rejected.latestReplyableId == "answer-34")
        #expect(service.activeCount == 0 && service.pendingCount == 0)
        #expect(service.peakChunkBytes <= ReplyLastAvailabilityPreparation.inputByteLimit)
    }

    @Test(.timeLimit(.minutes(2))) func storageGenerationRejectsCanonicallyEqualReplacements() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "equal-storage", agentId: nil, gateway: gateway, headless: true)
        let service = ReplyLastAvailabilityPreparation()
        chat.replyLastPreparation = service
        let gate = Gate()
        service.chunkGate = { await gate.hold() }
        defer { Task { await gate.release() } }
        let pair = await Task.detached { () -> (String, String) in
            let old = NSString(string: String(repeating: "\u{2003}", count: 5000) + "é") as String
            let new = String(repeating: "\u{2003}", count: 5000) + "e\u{301}"
            return (old, new)
        }.value
        try #require(!pair.0.isContiguousUTF8, "actual foreign NSString storage is required")
        #expect(pair.0 == pair.1, "different UTF16 encodings compare canonically equal")
        chat.items = [self.item("equal", blocks: [.text(pair.0)])]
        let revision = chat.contentRevision
        let generation = chat.replyLastSourceGeneration
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.arrived()) && ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.arrived())
        chat.items = [self.item("equal", blocks: [.text(pair.1)])]
        #expect(chat.contentRevision == revision, "canonical equality must not be used as storage identity")
        #expect(chat.replyLastSourceGeneration > generation)
        await gate.release()
        await service.waitUntilIdle()
        #expect(chat.latestReplyableId == "equal")
        let ready = chat.replyLastPreparedRevision
        let same = chat.items
        chat.items = same
        #expect(chat.replyLastPreparedRevision == ready, "logically equal warm eligibility remains reusable")
        #expect(chat.latestReplyableId == "equal")
    }

    @Test(.timeLimit(.minutes(2))) func unsupportedSourceAndCanceledDrainDoNotLoopOrHang() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "unsupported", agentId: nil, gateway: gateway, headless: true)
        let service = ReplyLastAvailabilityPreparation()
        chat.replyLastPreparation = service
        chat.items = [self.item(String(repeating: "id", count: 200), blocks: [.text("Answer")])]
        await service.waitUntilIdle()
        let admission = service.admissionRevision
        for _ in 0..<10 { #expect(chat.latestReplyableId == nil) }
        #expect(service.activeCount == 0 && service.admissionRevision == admission,
                "unsupported generation is cached rather than endlessly readmitted")
        let gate = Gate()
        service.chunkGate = { await gate.hold() }
        defer { Task { await gate.release() } }
        chat.items = [self.item("held", blocks: [.text("Answer")])]
        let drain = Task { await service.waitUntilIdle() }
        let deadline = ContinuousClock.now + .seconds(5)
        while service.drainWaiterCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        try #require(service.drainWaiterCount == 1)
        drain.cancel()
        await drain.value
        #expect(service.drainWaiterCount == 0 && service.activeCount == 1)
        await service.waitUntilIdle(timeout: .milliseconds(5))
        #expect(service.drainWaiterCount == 0, "deadline drains remove their registration")
        chat.cancelReplyLastAvailability()
        await gate.release()
        await service.waitUntilIdle()
        #expect(chat.replyLastPreparedRevision == nil, "stop rejects held publication")
    }

    @Test(.timeLimit(.minutes(2))) func warmAvailabilityDoesNotObserveUnrelatedAdmissionCompletion() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let service = ReplyLastAvailabilityPreparation()
        let warm = ChatStore(sessionKey: "warm-observation", agentId: nil, gateway: gateway, headless: true)
        warm.replyLastPreparation = service
        warm.items = [self.item("warm-target", blocks: [.text("Warm answer")])]
        await service.waitUntilIdle()
        let invalidations = Mutex(0)
        let selected = withObservationTracking { warm.latestReplyableId } onChange: {
            invalidations.withLock { $0 += 1 }
        }
        #expect(selected == "warm-target")
        let unrelated = ChatStore(sessionKey: "unrelated-observation", agentId: nil, gateway: gateway, headless: true)
        unrelated.replyLastPreparation = service
        unrelated.items = [self.item("unrelated-target", blocks: [.text("Unrelated answer")])]
        await service.waitUntilIdle()
        #expect(unrelated.latestReplyableId == "unrelated-target")
        #expect(invalidations.withLock { $0 } == 0,
                "a warm actual availability getter must not invalidate for unrelated global admission")
    }

    @Test(.timeLimit(.minutes(2))) func rejectedColdAvailabilityObservesFreedCapacityAndRetries() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let service = ReplyLastAvailabilityPreparation()
        let gate = Gate()
        service.chunkGate = { await gate.hold() }
        defer { Task { await gate.release() } }
        let owners = (0..<33).map { index in
            let chat = ChatStore(sessionKey: "admission-owner-\(index)", agentId: nil, gateway: gateway, headless: true)
            chat.replyLastPreparation = service
            chat.items = [self.item("owned-target-\(index)", blocks: [.text("Answer")])]
            return chat
        }
        let rejected = ChatStore(sessionKey: "cold-observation", agentId: nil, gateway: gateway, headless: true)
        rejected.replyLastPreparation = service
        rejected.items = [self.item("rejected-target", blocks: [.text("Rejected answer")])]
        let invalidations = Mutex(0)
        let selected = withObservationTracking { rejected.latestReplyableId } onChange: {
            invalidations.withLock { $0 += 1 }
        }
        #expect(selected == nil && service.pendingCount == 32)
        await gate.release()
        await service.waitUntilIdle()
        #expect(invalidations.withLock { $0 } > 0, "cold actual getter observes freed capacity")
        #expect(rejected.latestReplyableId == nil)
        await service.waitUntilIdle()
        #expect(rejected.latestReplyableId == "rejected-target")
        withExtendedLifetime(owners) {}
    }

    @Test(.timeLimit(.minutes(2))) func immediateNewestUserDoesNotObserveUnrelatedAdmission() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let service = ReplyLastAvailabilityPreparation()
        let gate = Gate()
        service.chunkGate = { await gate.hold() }
        defer { Task { await gate.release() } }
        let unrelated = ChatStore(sessionKey: "held-unrelated-user-control", agentId: nil, gateway: gateway, headless: true)
        unrelated.replyLastPreparation = service
        unrelated.items = [self.item("held-unrelated", blocks: [.text("Answer")])]
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.arrived()) && ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.arrived())
        let immediate = ChatStore(sessionKey: "immediate-user-observation", agentId: nil, gateway: gateway, headless: true)
        immediate.replyLastPreparation = service
        immediate.items = [self.item("immediate-user", role: .user, blocks: [])]
        try #require(immediate.replyLastPreparedRevision == nil, "user shortcut is genuinely cold")
        let invalidations = Mutex(0)
        let selected = withObservationTracking { immediate.latestReplyableId } onChange: {
            invalidations.withLock { $0 += 1 }
        }
        #expect(selected == "immediate-user")
        // Remove this user's pending job without changing its observed ready revision.
        service.cancel(immediate)
        await gate.release()
        await service.waitUntilIdle()
        #expect(invalidations.withLock { $0 } == 0,
                "the immediate user shortcut must not observe unrelated admission completion")
        #expect(immediate.latestReplyableId == "immediate-user")
    }

}
