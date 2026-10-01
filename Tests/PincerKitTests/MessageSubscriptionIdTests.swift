import Foundation
import Testing
@testable import PincerKit

/// #274: message subscriptions carry a stable `subscriptionId`, with a fallback for older Gateways.
@MainActor
@Suite("Message subscription id", .serialized)
struct MessageSubscriptionIdTests {
    let key = "agent:main:main"

    func chat(_ h: PrefsHarness, key: String? = nil) -> ChatStore {
        ChatStore(sessionKey: key ?? self.key, agentId: nil, gateway: h.store, headless: true)
    }

    func ids(_ h: PrefsHarness, _ method: String) -> [String?] {
        h.gateway.subscriptions.filter { $0.method == method }.map { $0.params["subscriptionId"]?.string }
    }

    @Test func idIsStableAcrossResubscribesAndReusedOnUnsubscribe() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        let chat = self.chat(h)
        try await chat.subscribeToMessages(on: h.store)
        try await chat.subscribeToMessages(on: h.store)
        let subscribed = self.ids(h, "sessions.messages.subscribe")
        #expect(subscribed == [chat.subscriptionId, chat.subscriptionId])
        #expect(UUID(uuidString: chat.subscriptionId) != nil)
        #expect(chat.unsubscribeParams()["subscriptionId"]?.string == chat.subscriptionId)
        #expect(chat.unsubscribeParams()["key"]?.string == key)
    }

    @Test func eachChatHasItsOwnId() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        #expect(self.chat(h).subscriptionId != self.chat(h, key: "agent:main:other").subscriptionId)
    }

    @Test func releaseSendsTheSameIdOnTheWire() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        let chat = self.chat(h)
        try await chat.subscribeToMessages(on: h.store)
        chat.subscribedEpoch = h.store.connectionEpoch
        await chat.releaseSubscription()
        #expect(self.ids(h, "sessions.messages.unsubscribe") == [chat.subscriptionId])
    }

    @Test func oldGatewayFallsBackOnceWithoutTheId() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.rejectsSubscriptionIds = true
        let chat = self.chat(h)
        try await chat.subscribeToMessages(on: h.store)
        #expect(self.ids(h, "sessions.messages.subscribe") == [chat.subscriptionId, nil])
        #expect(h.store.messageSubscriptionIdUnsupported)
        #expect(!chat.subscribedWithId)
        // Later subscriptions on this connection don't try the id again.
        let other = self.chat(h, key: "agent:main:other")
        try await other.subscribeToMessages(on: h.store)
        #expect(self.ids(h, "sessions.messages.subscribe").suffix(1) == [nil])
        #expect(self.ids(h, "sessions.messages.subscribe").count == 3)
    }

    @Test func unsubscribeAfterFallbackSendsNoId() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.rejectsSubscriptionIds = true
        let chat = self.chat(h)
        try await chat.subscribeToMessages(on: h.store)
        #expect(chat.unsubscribeParams()["subscriptionId"] == nil)
        chat.subscribedEpoch = h.store.connectionEpoch
        await chat.releaseSubscription()
        #expect(self.ids(h, "sessions.messages.unsubscribe") == [nil])
    }

    @Test func otherRejectionsAreNotTakenForAnOldGateway() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        #expect(!h.store.messageSubscriptionIdUnsupported)
        let chat = self.chat(h)
        try await chat.subscribeToMessages(on: h.store)
        #expect(!h.store.messageSubscriptionIdUnsupported)
        #expect(chat.subscribedWithId)
    }
}
