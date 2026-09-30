import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the demo's seeded unsent message lives, for checks and screenshots.
public enum DemoOutbox {
    /// The *Dinner party* chat, a demo chat of its own so the failed message (which blocks later
    /// sends in its chat until Retry or Delete) doesn't get in the way of the other demo chats.
    public static let sessionKey = "agent:main:dashboard:dinner"
    /// The seeded failed message's idempotency key.
    public static let failedId = "demo-outbox-failed-shopping-list"
    /// The seeded queued message with the seating-plan image, behind the failed one.
    public static let queuedAttachmentId = "demo-outbox-queued-seating-plan"
    static let seatingPlanId = UUID(uuidString: "5EA71A9E-0000-4000-8000-000000000483")!
    static let seatingPlanRef = OutboxAttachmentRef(
        id: seatingPlanId, fileName: "seating-plan.png", mimeType: "image/png",
        byteCount: DemoGateway.seatingPlan.data.count)
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
                state: .failed(OutboxFailure(message: "The Gateway timed out.", retryable: true)),
                attempts: 1),
            OutboxEntry(
                id: DemoOutbox.queuedAttachmentId,
                sessionKey: DemoOutbox.sessionKey,
                agentId: "main",
                text: "And here’s the seating plan — can you check nobody’s sitting next to their ex?",
                createdAt: now.addingTimeInterval(-30),
                attachments: [DemoOutbox.seatingPlanRef]),
        ]
    }

    /// The seated-plan image the queued message carries, generated once.
    static let seatingPlan = OutgoingAttachment(
        id: DemoOutbox.seatingPlanId, fileName: "seating-plan.png", mimeType: "image/png", data: DemoGateway.seatingPlanPNG())

    /// A 240×160 table diagram: a round table with six seats.
    static func seatingPlanPNG() -> Data {
        let (width, height) = (240, 160)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        context.setFillColor(CGColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let center = CGPoint(x: 120, y: 80)
        context.setFillColor(CGColor(red: 0.72, green: 0.52, blue: 0.36, alpha: 1))
        context.fillEllipse(in: CGRect(x: center.x - 42, y: center.y - 42, width: 84, height: 84))
        for seat in 0..<6 {
            let angle = CGFloat(seat) * .pi / 3 + .pi / 6
            let hue = CGFloat(seat) / 6
            context.setFillColor(CGColor(red: 0.30 + hue * 0.5, green: 0.55 - hue * 0.2, blue: 0.80 - hue * 0.5, alpha: 1))
            context.fillEllipse(in: CGRect(x: center.x + cos(angle) * 62 - 13, y: center.y + sin(angle) * 62 - 13, width: 26, height: 26))
        }
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
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
