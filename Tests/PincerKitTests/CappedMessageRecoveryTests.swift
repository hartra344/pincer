import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Capped message recovery", .serialized)
struct CappedMessageRecoveryTests {
    private enum RequestFailure: Error { case transient }

    private let scratch = ScratchDefaults()

    func makeChat() -> (ChatStore, GatewayStore) {
        let profile = GatewayProfile(name: "Recovery", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        return (ChatStore(sessionKey: "agent:main:dashboard:recovery", agentId: "main", gateway: gateway, headless: true), gateway)
    }

    func message(_ role: String, id: String, text: String, capped: Bool = false) -> JSONValue {
        var metadata: [String: JSONValue] = ["id": .string(id)]
        if capped { metadata["truncated"] = .bool(true) }
        return ["role": .string(role), "content": .string(text), "__openclaw": .object(metadata)]
    }

#if DEBUG
    @Test func ordinaryAcceptedMessageDoesNoCappedRecoveryScan() {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        chat.hasLoaded = true
        chat.items = (0..<512).map { index in
            ChatItem(id: "existing-\(index)", role: .user, blocks: [.text("row \(index)")])
        }
        chat.resetCappedRecoveryRowsVisitedForTesting()

        chat.handleSessionMessage(["message": self.message("user", id: "new-ordinary", text: "ordinary message")])

        #expect(chat.items.count == 513)
        #expect(chat.cappedRecoveryRowsVisitedForTesting == 0 && chat.acceptedEventRecoveryRowsVisitedForTesting == 0,
                "an ordinary accepted event must not scan unrelated transcript rows")
    }
#endif

    @Test func cachedFullCopyRestoresSameIDRedeliveryIncludingPendingInputPrefix() throws {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        chat.hasLoaded = true

        let assistantId = "capped-assistant"
        let assistantCap = try #require(ChatItem(self.message("assistant", id: assistantId, text: "short", capped: true), fallbackIndex: 0))
        let assistantFull = try #require(ChatItem(self.message("assistant", id: assistantId, text: "complete assistant body"), fallbackIndex: 0))
        chat.items = [assistantCap]
        chat.fullMessages[assistantId] = assistantFull
        chat.handleSessionMessage(["message": self.message("assistant", id: assistantId, text: "short", capped: true)])
        #expect(chat.items.first?.plainText == "complete assistant body")
        #expect(chat.items.first?.id == assistantCap.id && chat.items.first?.transcriptId == assistantId)

        let pendingId = ChatItem.pendingInputPrefix + "pending-capped"
        let pendingCap = try #require(ChatItem(self.message("user", id: pendingId, text: "preview", capped: true), fallbackIndex: 1))
        let pendingFull = try #require(ChatItem(self.message("user", id: pendingId, text: "complete pending input"), fallbackIndex: 1))
        #expect(pendingCap.isCapped && !pendingCap.isReplyable,
                "pending user-input rows are recoverable despite being absent from the replyable index")
        chat.items = [pendingCap]
        chat.fullMessages[pendingId] = pendingFull
        chat.handleSessionMessage(["message": self.message("user", id: pendingId, text: "preview", capped: true)])
        #expect(chat.items.first?.plainText == "complete pending input")
        #expect(chat.items.first?.id == pendingCap.id && chat.items.first?.transcriptId == pendingId)
    }

    @Test func bulkRecoveryInstallStillRestoresCachedFullCopyOnTheNextEvent() {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "bulk-installed-capped"
        let capped = ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 0)!
        let full = ChatItem(self.message("assistant", id: id, text: "restored after bulk install"), fallbackIndex: 0)!
        chat.hasLoaded = true
        chat.fullMessages[id] = full

        chat.replaceRecoveryItems([capped])
        chat.handleSessionMessage(["message": self.message("user", id: "after-bulk-install", text: "ordinary event")])

        #expect(chat.items.first?.id == capped.id && chat.items.first?.transcriptId == id)
        #expect(chat.items.first?.plainText == "restored after bulk install",
                "a cached full copy remains restorable after a bulk install into an already-loaded chat")
    }

#if DEBUG
    @Test func bulkRecoveryIsConsumedOnceAndTheNextOrdinaryEventDoesNoScan() async {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "bulk-recovery-consumed"
        let capped = ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 0)!
        let full = ChatItem(self.message("assistant", id: id, text: "restored once"), fallbackIndex: 0)!
        chat.hasLoaded = true
        chat.fullMessages[id] = full
        chat.replaceRecoveryItems([capped])

        chat.handleSessionMessage(["message": self.message("user", id: "consume-bulk-recovery", text: "ordinary event")])
        #expect(chat.items.first?.plainText == "restored once")
        chat.resetCappedRecoveryRowsVisitedForTesting()

        chat.handleSessionMessage(["message": self.message("user", id: "after-bulk-recovery", text: "next ordinary event")])

        #expect(chat.items.first?.plainText == "restored once")
        #expect(chat.acceptedEventRecoveryRowsVisitedForTesting == 0,
                "after bulk-installed capped content is restored, ordinary events do not rescan the transcript")
    }

    @Test func applyingHistoryConsumesCachedRecoveryBeforeLaterOrdinaryEvents() {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "history-capped"
        let older = ChatItem(self.message("user", id: "older-row", text: "older"), fallbackIndex: 0)!
        let capped = ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 1)!
        let full = ChatItem(self.message("assistant", id: id, text: "complete from cache"), fallbackIndex: 1)!
        chat.hasLoaded = true
        chat.hasPagedOlder = true
        chat.replaceRecoveryItems([older, capped])
        chat.fullMessages[id] = full
        let history: JSONValue = ["messages": .array([self.message("assistant", id: id, text: "preview", capped: true)])]

        chat.apply(history: history, parsed: [capped])

        #expect(chat.items.map(\.id) == [older.id, capped.id])
        #expect(chat.items.last?.plainText == "complete from cache",
                "applying a history page restores the cached full copy in the same apply pass")
        chat.resetCappedRecoveryRowsVisitedForTesting()
        chat.handleSessionMessage(["message": self.message("user", id: "after-history", text: "ordinary event")])

        #expect(chat.acceptedEventRecoveryRowsVisitedForTesting == 0,
                "history-restored content is no longer eligible for repeated recovery scans")
    }

    @Test func missingGatewayRecoveryRearmsAndRetriesAfterGatewayReturns() async {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "temporarily-unavailable-capped"
        chat.hasLoaded = true
        chat.items = [ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 0)!]
        chat.gateway = nil

        chat.recoverCappedMessages()
        #expect(await eventually { !chat.recoveryAttempted.contains(id) },
                "without a Gateway the failed attempt is cleared so the capped row remains eligible")

        var requests = 0
        chat.cappedMessageRecoveryRequestForTesting = { requestedId in
            #expect(requestedId == id)
            requests += 1
            return ["ok": .bool(true), "message": self.message("assistant", id: id, text: "restored after Gateway returns")]
        }
        chat.gateway = gateway
        chat.handleSessionMessage(["message": self.message("user", id: "gateway-returned", text: "ordinary event")])

        #expect(await eventually { requests == 1 && chat.items.first?.plainText == "restored after Gateway returns" },
                "a later accepted event retries recovery after a Gateway is reattached")
    }
#endif

#if DEBUG
    @Test func startupUncappedEventStillRecoversExistingCappedRows() async {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "startup-capped"
        let capped = ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 0)!
        chat.hasLoaded = false
        chat.items = [capped]
        var requests = 0
        chat.cappedMessageRecoveryRequestForTesting = { requestedId in
            #expect(requestedId == id)
            requests += 1
            return ["ok": .bool(true), "message": self.message("assistant", id: id, text: "startup restored")]
        }

        chat.handleSessionMessage(["message": self.message("user", id: "startup-event", text: "ordinary startup event")])

        #expect(await eventually { requests == 1 && chat.items.first?.plainText == "startup restored" },
                "an uncapped event retains the startup pass that recovers already loaded capped rows")
    }

    @Test func disconnectedRecoveryRemainsEligibleForTheNextEvent() async {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "disconnected-capped"
        chat.hasLoaded = true
        chat.items = [ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 0)!]

        chat.recoverCappedMessages()
        #expect(await eventually { !chat.recoveryAttempted.contains(id) },
                "a disconnected Gateway leaves the capped row eligible for a later pass")

        var requests = 0
        chat.cappedMessageRecoveryRequestForTesting = { requestedId in
            #expect(requestedId == id)
            requests += 1
            return ["ok": .bool(true), "message": self.message("assistant", id: id, text: "restored after reconnect")]
        }
        chat.handleSessionMessage(["message": self.message("user", id: "reconnected-event", text: "ordinary event")])

        #expect(await eventually { requests == 1 && chat.items.first?.plainText == "restored after reconnect" },
                "a subsequent event retries recovery after the disconnected guard")
    }

    @Test func notFoundRefusalRetainsAttemptAndDoesNotRetryOnOrdinaryEvent() async {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "missing-capped"
        chat.hasLoaded = true
        chat.items = [ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 0)!]
        var requests = 0
        var requestFinished = false
        chat.cappedMessageRecoveryRequestForTesting = { requestedId in
            #expect(requestedId == id)
            requests += 1
            requestFinished = true
            return ["ok": .bool(false), "unavailableReason": .string("not_found")]
        }

        chat.recoverCappedMessages()
        #expect(await eventually { requestFinished && chat.recoveryAttempted.contains(id) },
                "a Gateway not-found refusal leaves the attempt marked")
        chat.handleSessionMessage(["message": self.message("user", id: "later-event", text: "ordinary event")])

        #expect(requests == 1 && chat.recoveryAttempted.contains(id),
                "a later ordinary event does not retry a refused not-found result")
    }

    @Test func unrelatedAcceptedMessageRetriesTransportFailedCappedRecovery() async {
        let (chat, gateway) = self.makeChat()
        defer { chat.stopCaching(); gateway.stop(); self.scratch.remove() }
        let id = "retry-capped"
        let capped = ChatItem(self.message("assistant", id: id, text: "preview", capped: true), fallbackIndex: 0)!
        chat.hasLoaded = true
        chat.items = [capped]
        var requests = 0
        chat.cappedMessageRecoveryRequestForTesting = { requestedId in
            #expect(requestedId == id)
            requests += 1
            if requests == 1 { throw RequestFailure.transient }
            return ["ok": .bool(true), "message": self.message("assistant", id: id, text: "restored after retry")]
        }

        chat.recoverCappedMessages()
        #expect(await eventually { requests == 1 && !chat.recoveryAttempted.contains(id) },
                "the first transport failure makes this ID eligible for retry")

        chat.handleSessionMessage(["message": self.message("user", id: "unrelated-event", text: "new user message")])
        #expect(await eventually { requests == 2 && chat.items.first?.plainText == "restored after retry" },
                "a later accepted event retries the capped row without losing its cached identity")
    }
#endif
}
