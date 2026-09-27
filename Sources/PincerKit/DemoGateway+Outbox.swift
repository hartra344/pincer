import Foundation

/// Where the demo's seeded unsent message lives, for checks and screenshots.
public enum DemoOutbox {
    /// The Japan trip chat.
    public static let sessionKey = "agent:main:dashboard:trip"
    /// The seeded failed message's idempotency key.
    public static let failedId = "demo-outbox-failed-ryokan"
}

extension DemoGateway {
    /// Client-side outbox seed for the demo (#46): one message that failed to send, shown inline
    /// with Retry at the end of the trip chat. The demo Gateway accepts it on Retry. The demo
    /// `GatewayStore` injects these with `injectOutboxEntry(_:)` at start.
    static func seedOutbox(now: Date = Date()) -> [OutboxEntry] {
        [
            OutboxEntry(
                id: DemoOutbox.failedId,
                sessionKey: DemoOutbox.sessionKey,
                agentId: "main",
                text: "Can you also hold a ryokan in Hakone for the night of the 14th? Private onsen if possible.",
                createdAt: now.addingTimeInterval(-40),
                state: .failed(OutboxFailure(message: "Couldn’t send: the connection dropped.", retryable: true)),
                attempts: 1),
        ]
    }
}
