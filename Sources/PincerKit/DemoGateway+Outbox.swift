import Foundation

/// Where the demo's seeded unsent message lives, for checks and screenshots.
public enum DemoOutbox {
    /// The *Dinner party* chat, a demo chat of its own so the failed message (which blocks later
    /// sends in its chat until Retry or Delete) doesn't get in the way of the other demo chats.
    public static let sessionKey = "agent:main:dashboard:dinner"
    /// The seeded failed message's idempotency key.
    public static let failedId = "demo-outbox-failed-shopping-list"
    static let title = "Dinner party"
    static let preview = "Pinot Noir suits both Wellingtons."
}

extension DemoGateway {
    /// Client-side outbox seed for the demo (#46): one message that failed to send, shown inline
    /// with Retry at the end of the *Dinner party* chat. The demo Gateway accepts it on Retry. The
    /// demo `GatewayStore` injects these with `injectOutboxEntry(_:)` at start.
    static func seedOutbox(now: Date = Date()) -> [OutboxEntry] {
        [
            OutboxEntry(
                id: DemoOutbox.failedId,
                sessionKey: DemoOutbox.sessionKey,
                agentId: "main",
                text: "Great, can you turn that into a shopping list grouped by aisle?",
                createdAt: now.addingTimeInterval(-40),
                state: .failed(OutboxFailure(message: "The gateway timed out.", retryable: true)),
                attempts: 1),
        ]
    }

    /// The Gateway-side transcript of the *Dinner party* chat the failed message follows.
    static func seedOutboxTranscript() -> [JSONValue] {
        let minute = 60.0, day = 86400.0
        return [
            Self.message("user", [Self.text("I'm hosting six people on Saturday. One is vegetarian. Plan a menu?")],
                         ago: day + 6 * minute),
            Self.message("assistant", [Self.text("""
            Here's a menu that works for everyone:

            - **Starter:** burrata with roasted peaches and basil
            - **Main:** mushroom and chestnut Wellington, with a small beef fillet for the meat eaters
            - **Sides:** crispy smashed potatoes, charred greens with lemon
            - **Dessert:** olive oil cake with crème fraîche

            The Wellington and the cake can both be made the day before.
            """)], ago: day + 5 * minute),
            Self.message("user", [Self.text("Perfect. What wine goes with it?")], ago: 3 * minute),
            Self.message("assistant", [Self.text("""
            A Pinot Noir from Burgundy or Oregon suits both Wellingtons; for the starter, a crisp \
            Vermentino. Two bottles of each is plenty for six.
            """)], ago: 2 * minute),
        ]
    }
}
