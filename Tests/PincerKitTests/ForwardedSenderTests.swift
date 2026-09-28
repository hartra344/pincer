import Foundation
import Testing
@testable import PincerKit

/// Messages from another agent, an automation or a helper (#207).
@Suite("Forwarded senders")
struct ForwardedSenderTests {
    static let agents = [AgentSummary(id: "main", name: "Claw", emoji: "🦞"), AgentSummary(id: "kiko", name: "Kiko", emoji: "🌕")]
    static let prefix = "[Inter-session message] sourceSession=agent:kiko:main sourceChannel=internal sourceTool=sessions_send isUser=false"

    static func items(_ text: String) -> [ChatItem] {
        Fixtures.json(text).array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
    }

    static func turns(_ items: [ChatItem]) -> [AssistantTurn] {
        TranscriptBuilder.build(items).compactMap { if case let .assistant(turn) = $0 { turn } else { nil } }
    }

    @Test func projectedMessageIsFromTheSendingAgent() {
        let item = Self.items(#"""
        [{"role":"assistant","content":[{"type":"text","text":"Hi Claw! I'm Kiko."}],
          "provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:kiko:main","sourceChannel":"internal"},
          "senderSession":{"sessionKey":"agent:kiko:main","agentId":"kiko"},"senderLabel":"Forwarded from kiko",
          "__openclaw":{"id":"k1","runId":"r1"}}]
        """#)[0]
        #expect(item.role == .assistant)
        #expect(item.sender == MessageSender(kind: .agent, sessionKey: "agent:kiko:main", agentId: "kiko"))
        #expect(item.sender?.displayName(agents: Self.agents) == "Kiko")
        #expect(item.sender?.marker(agents: Self.agents, receivingAgentId: "main") == "from Kiko’s chat")
        #expect(item.sender?.canOpenSource == true)
        #expect(item.senderName(you: "You", agent: "Claw", agents: Self.agents) == "Kiko")
        #expect(item.via == nil, "an internal sourceChannel isn't a bridged channel")
    }

    @Test func rawInterSessionTurnIsAttributedAndCleaned() {
        let text = "\(Self.prefix)\n\(MessageSender.interSessionPromptExplanation)\nHi Claw!"
        let body = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        let item = Self.items("""
        [{"role":"user","content":[{"type":"text","text":\(body)}],
          "provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:kiko:main"},"__openclaw":{"id":"k1"}}]
        """)[0]
        #expect(item.role == .assistant)
        #expect(item.sender?.agentId == "kiko" && item.sender?.kind == .agent)
        #expect(item.plainText == "Hi Claw!")
    }

    @Test func prefixStripping() {
        #expect(MessageSender.stripInterSessionPrefix("\(Self.prefix)\n\(MessageSender.interSessionPromptExplanation)\nhello") == "hello")
        #expect(MessageSender.stripInterSessionPrefix("\(Self.prefix)\nhello") == "hello")
        #expect(MessageSender.stripInterSessionPrefix("hello") == "hello")
        // As upstream's stripInterSessionPromptPrefixForDisplay: text before the header is kept.
        #expect(MessageSender.stripInterSessionPrefix("Note \(Self.prefix)\nhello") == "Note\nhello")
    }

    @Test func sendersBreakGroups() {
        let items = Self.items(#"""
        [
         {"role":"assistant","content":"Hi Claw!","senderSession":{"sessionKey":"agent:kiko:main","agentId":"kiko"},
          "provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:kiko:main"},"__openclaw":{"id":"a","runId":"r1"}},
         {"role":"assistant","content":"Hi Kiko!","__openclaw":{"id":"b","runId":"r1"}},
         {"role":"assistant","content":"Thanks!","senderSession":{"sessionKey":"agent:kiko:main","agentId":"kiko"},
          "provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:kiko:main"},"__openclaw":{"id":"c","runId":"r2"}},
         {"role":"assistant","content":"Noted.","__openclaw":{"id":"d","runId":"r2"}},
         {"role":"assistant","content":"And one more thing.","__openclaw":{"id":"e","runId":"r2"}},
         {"role":"user","content":"Thanks both","__openclaw":{"id":"f"}}
        ]
        """#)
        let entries = TranscriptBuilder.build(items)
        #expect(entries.count == 5)
        let turns = Self.turns(items)
        #expect(turns.map { $0.sender?.agentId } == ["kiko", nil, "kiko", nil])
        #expect(turns.map(\.body) == ["Hi Claw!", "Hi Kiko!", "Thanks!", "Noted.\n\nAnd one more thing."],
                "the receiving agent's own messages still group together")
    }

    @Test func automationsAndHelpers() {
        let items = Self.items(#"""
        [
         {"role":"assistant","content":"Write my briefing","senderSession":{"sessionKey":"agent:main:cron:mb:run:r","agentId":"main","label":"Morning briefing"},
          "provenance":{"kind":"internal_system","sourceTool":"cron","jobId":"mb","runId":"r","sourceSessionKey":"agent:main:cron:mb:run:r"},"__openclaw":{"id":"c1"}},
         {"role":"user","content":"Result: 3 links","provenance":{"kind":"inter_session","sourceTool":"subagent_announce","sourceSessionKey":"agent:main:subagent:x"},"__openclaw":{"id":"h1"}},
         {"role":"user","content":"Ping","provenance":{"kind":"inter_session","sourceTool":"sessions_send"},"__openclaw":{"id":"u1"}},
         {"role":"user","content":"hi","provenance":{"kind":"external_user","sourceChannel":"discord"},"__openclaw":{"id":"x1"}}
        ]
        """#)
        #expect(items[0].sender?.kind == .automation && items[0].sender?.displayName(agents: Self.agents) == "Morning briefing")
        #expect(items[0].sender?.canOpenSource == false)
        #expect(items[1].sender?.kind == .helper && items[1].sender?.displayName(agents: Self.agents) == MessageSender.helperName)
        #expect(items[2].sender?.displayName(agents: Self.agents) == MessageSender.unknownAgentName)
        #expect(items[2].sender?.canOpenSource == false)
        #expect(items[3].sender == nil && items[3].role == .user && items[3].via == "Discord")
    }

    /// The demo's seeded exchange reads Kiko, Claw, Kiko, Claw, you.
    @Test func demoSeedAlternatesSenders() {
        let items = DemoGateway.seedKikoIntroInClaw().enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
        let entries = TranscriptBuilder.build(items)
        let senders: [String] = entries.map { entry in
            switch entry {
            case let .assistant(turn): turn.sender?.displayName(agents: Self.agents) ?? "Claw"
            case .user: "You"
            case .marker: "-"
            }
        }
        #expect(senders == ["Kiko", "Claw", "Kiko", "Claw", "You"])
        #expect(items.first?.model == nil, "a forwarded message isn't credited to the receiving chat's model")
    }
}
