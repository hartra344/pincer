import Foundation

/// Kiko, the demo's finance agent, introduces herself to Claw with `sessions_send` (#207).
///
/// Claw's main chat holds the exchange as the Gateway's `chat.history` projects it
/// (`projectForwardedMessages` in `src/gateway/chat-display-projection.history.ts`): each message
/// Kiko sent is an assistant message with `senderSession`, `senderLabel` and the original
/// `provenance`, in the run it started, followed by Claw's reply in that run.
extension DemoGateway {
    static let kikoKey = "agent:kiko:main"
    static let kikoIntroId = "demo-kiko-intro"
    static let kikoThanksId = "demo-kiko-thanks"
    static let kikoIntroRunId = "demo-run-kiko-intro"
    static let kikoThanksRunId = "demo-run-kiko-thanks"

    static let kikoIntroText = """
    Hi Claw! I'm Kiko, Alex's new finance assistant. I'm putting together his monthly budget. Which \
    home-lab services renew on a schedule, and roughly what do they cost?
    """
    static let kikoThanksText = "Thanks Claw, that's everything I need. I've added all three to the budget. Talk soon!"

    /// A message Kiko sent to another chat, as `chat.history` shows it in that chat.
    static func fromKiko(_ text: String, id: String, runId: String, ago: Double) -> JSONValue {
        guard case var .object(fields) = Self.message("assistant", [Self.text(text)], runId: runId, id: id, ago: ago)
        else { return .null }
        // The forwarded prompt was a user turn: no model of this chat ran it.
        fields["provider"] = nil
        fields["model"] = nil
        fields["provenance"] = [
            "kind": "inter_session", "sourceSessionKey": .string(Self.kikoKey),
            "sourceChannel": "internal", "sourceTool": "sessions_send",
        ]
        fields["senderSession"] = ["sessionKey": .string(Self.kikoKey), "agentId": "kiko"]
        fields["senderLabel"] = "Forwarded from kiko"
        return .object(fields)
    }

    /// When Alex asked Kiko to reach out: a day before launch.
    private static let kikoAskAgo = 86400.0 + 3 * 60

    static let clawReplyToKiko = """
    Hi Kiko, welcome aboard! Three things renew on a schedule:

    - **Backblaze B2** storage: about $6 a month.
    - **Tailscale**: free for Alex's plan.
    - The **clawhouse.dev** domain: $12 a year, next due in March.

    The NAS drives are also due for replacement next spring, around $400.
    """
    static let clawNoteAfterKiko = """
    Kiko is tracking the home-lab bills now, so renewals will show up in her monthly summary. Nothing \
    for you to do.
    """

    /// The exchange in Claw's main chat.
    static func seedKikoIntroInClaw() -> [JSONValue] {
        let at = Self.kikoAskAgo
        return [
            Self.fromKiko(Self.kikoIntroText, id: Self.kikoIntroId, runId: Self.kikoIntroRunId, ago: at - 12),
            Self.message("assistant", [Self.text(Self.clawReplyToKiko)], runId: Self.kikoIntroRunId,
                         id: "demo-claw-to-kiko", ago: at - 32),
            Self.fromKiko(Self.kikoThanksText, id: Self.kikoThanksId, runId: Self.kikoThanksRunId, ago: at - 72),
            Self.message("assistant", [Self.text(Self.clawNoteAfterKiko)], runId: Self.kikoThanksRunId,
                         id: "demo-claw-kiko-note", ago: at - 87),
            Self.message("user", [Self.text("Nice, thanks both 🙌")], id: "demo-main-thanks-both", ago: at - 180),
        ]
    }

    /// Kiko's own main chat, where Alex asked her to reach out.
    static func seedKikoChat() -> [JSONValue] {
        let at = Self.kikoAskAgo
        func send(_ call: String, _ text: String, runId: String, reply: String, ago: Double) -> [JSONValue] {
            let result: JSONValue = ["runId": .string(runId), "sessionKey": "agent:main:main", "status": "ok",
                                     "reply": .string(reply)]
            return [
                Self.message("assistant", [
                    Self.toolCall(call, "sessions_send", ["sessionKey": "agent:main:main", "message": .string(text)]),
                ], ago: ago),
                Self.message("toolResult", [Self.text(Self.jsonText(result))], ago: ago - 30,
                             extra: ["toolCallId": .string(call), "toolName": "sessions_send", "isError": false]),
            ]
        }
        return [Self.message("user", [Self.text("Introduce yourself to Claw and find out what the home lab costs each month.")],
                             id: "demo-kiko-ask", ago: at)]
            + send("call_seed_kiko_intro", Self.kikoIntroText, runId: Self.kikoIntroRunId, reply: Self.clawReplyToKiko, ago: at - 10)
            + send("call_seed_kiko_thanks", Self.kikoThanksText, runId: Self.kikoThanksRunId, reply: Self.clawNoteAfterKiko,
                   ago: at - 70)
            + [Self.message("assistant", [Self.text("""
            Claw sent the list: Backblaze B2 at about $6 a month, Tailscale for free and the domain at $12 a year. \
            I've added them to your budget, with $400 set aside for new NAS drives next spring.
            """)], id: "demo-kiko-summary", ago: at - 120)]
    }

    private static func jsonText(_ value: JSONValue) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
