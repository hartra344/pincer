import Foundation
import PincerKit

// Messages from another agent, an automation or a helper (#207).

/// Lumi's home chat after Kiko introduced herself with `sessions_send`, as the Gateway projects it
/// (`projectForwardedMessages` in `src/gateway/chat-display-projection.history.ts`): the forwarded
/// user turn becomes an assistant message with `senderSession`, in the run it started.
let forwardedFixture = """
[
 {"role":"assistant","content":[{"type":"text","text":"Hi Lumi! I'm Kiko, Travis's finance assistant."}],"timestamp":1000,
  "provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:kiko:main","sourceChannel":"internal"},
  "senderSession":{"sessionKey":"agent:kiko:main","agentId":"kiko"},"senderLabel":"Forwarded from kiko",
  "__openclaw":{"id":"f1","runId":"r1"}},
 {"role":"assistant","content":[{"type":"text","text":"Hi Kiko, nice to meet you!"}],"timestamp":2000,"model":"claude-opus-5.5",
  "__openclaw":{"id":"f2","runId":"r1"}},
 {"role":"assistant","content":[{"type":"text","text":"Thanks Lumi, that all works for me. Talk soon!"}],"timestamp":3000,
  "provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:kiko:main"},
  "senderSession":{"sessionKey":"agent:kiko:main","agentId":"kiko"},"__openclaw":{"id":"f3","runId":"r2"}},
 {"role":"assistant","content":[{"type":"text","text":"Kiko asked for no reply."}],"timestamp":4000,"__openclaw":{"id":"f4","runId":"r2"}},
 {"role":"user","content":"Yes I've confirmed it","timestamp":5000,"__openclaw":{"id":"f5"}}
]
"""

@MainActor
func checkForwardedMessages() {
    print("Forwarded messages (agent to agent)")
    let agents = [AgentSummary(id: "lumi", name: "Lumi", emoji: "📸"), AgentSummary(id: "kiko", name: "Kiko", emoji: "🌕")]
    func items(_ text: String) -> [ChatItem] {
        json(text).array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
    }
    func turns(_ entries: [TranscriptEntry]) -> [AssistantTurn] {
        entries.compactMap { if case let .assistant(turn) = $0 { turn } else { nil } }
    }

    // Projected (current Gateways): Kiko, Lumi, Kiko, Lumi, then you. Never one agent talking to itself.
    let projected = items(forwardedFixture)
    check(projected[0].sender?.kind == .agent && projected[0].sender?.agentId == "kiko", "projected senderSession → Kiko")
    check(projected[1].sender == nil, "the receiving agent's reply has no forwarded sender")
    let entries = TranscriptBuilder.build(projected)
    check(entries.count == 5, "each change of speaker starts a new group (got \(entries.count))")
    let rows = turns(entries)
    check(rows.map { $0.sender?.agentId } == ["kiko", nil, "kiko", nil], "groups alternate Kiko / Lumi / Kiko / Lumi")
    check(rows.first?.body == "Hi Lumi! I'm Kiko, Travis's finance assistant.", "Kiko's text stays in Kiko's group")
    check(rows.dropFirst().first?.body == "Hi Kiko, nice to meet you!", "Lumi's reply isn't merged into Kiko's group")
    check(rows.first?.sender?.displayName(agents: agents) == "Kiko", "sender name resolves from the agent list")
    check(rows.first?.sender?.canOpenSource == true, "Kiko's chat can be opened from the marker")
    check(rows.first?.sender?.marker(agents: agents, receivingAgentId: "lumi") == "from Kiko’s chat", "marker names the source chat")

    // Raw (older Gateways, or a live event before projection): user role with the model-facing prefix.
    let raw = items("""
    [
     {"role":"user","content":[{"type":"text","text":"[Inter-session message] sourceSession=agent:kiko:main sourceChannel=internal sourceTool=sessions_send isUser=false\\n\(MessageSender.interSessionPromptExplanation)\\nHi Lumi!"}],
      "provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:kiko:main"},"__openclaw":{"id":"g1","runId":"s1"}},
     {"role":"assistant","content":[{"type":"text","text":"Hi Kiko!"}],"__openclaw":{"id":"g2","runId":"s1"}}
    ]
    """)
    check(raw.first?.role == .assistant && raw.first?.sender?.agentId == "kiko", "raw inter-session user turn is shown as Kiko's")
    check(raw.first?.plainText == "Hi Lumi!", "inter-session prompt prefix and explanation are stripped (got \(raw.first?.plainText.debugDescription ?? "nil"))")
    check(turns(TranscriptBuilder.build(raw)).map { $0.sender?.agentId } == ["kiko", nil], "raw forwarded turn and the reply are separate groups")
    check(MessageSender.stripInterSessionPrefix("[Inter-session message] sourceSession=agent:a:main isUser=false\nhello") == "hello",
          "prefix without the explanation is stripped")
    check(MessageSender.stripInterSessionPrefix("plain text") == "plain text", "text without a prefix is unchanged")

    // Missing or unknown source.
    let unknown = items("""
    [
     {"role":"user","content":"Ping","provenance":{"kind":"inter_session","sourceTool":"sessions_send"},"__openclaw":{"id":"u1"}},
     {"role":"assistant","content":"Hi","provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceSessionKey":"agent:ghost:main"},
      "senderSession":{"sessionKey":"agent:ghost:main","agentId":"ghost"},"__openclaw":{"id":"u2"}}
    ]
    """)
    check(unknown.first?.sender?.displayName(agents: agents) == MessageSender.unknownAgentName, "missing sourceSessionKey → “Another agent”")
    check(unknown.first?.sender?.canOpenSource == false, "no source chat to open without a key")
    check(unknown.last?.sender?.displayName(agents: agents) == "Ghost", "unknown agent id falls back to the id")
    check(TranscriptBuilder.build(unknown).count == 2, "different senders never share a group")

    // Same agent, another of its chats.
    let sameAgent = MessageSender(kind: .agent, sessionKey: "agent:lumi:dashboard:ops")
    check(sameAgent.marker(agents: agents, receivingAgentId: "lumi") == "from another chat", "same agent's other chat reads “from another chat”")

    // Automations (cron) and helpers (subagents).
    let other = items("""
    [
     {"role":"user","content":[{"type":"text","text":"[cron:j1 Morning brief] Summarize the inbox"}],
      "provenance":{"kind":"internal_system","sourceTool":"cron","jobId":"j1","runId":"c1","sourceSessionKey":"agent:lumi:cron:j1:run:c1","sourcePromptPrefix":"[cron:j1 Morning brief]"},
      "__openclaw":{"id":"c1"}},
     {"role":"assistant","content":"Done","senderSession":{"sessionKey":"agent:lumi:cron:j2:run:c2","agentId":"lumi","label":"Weekly review"},
      "provenance":{"kind":"internal_system","sourceTool":"cron","jobId":"j2","runId":"c2","sourceSessionKey":"agent:lumi:cron:j2:run:c2"},"__openclaw":{"id":"c2"}},
     {"role":"user","content":"Research finished","provenance":{"kind":"inter_session","sourceTool":"sessions_send","sourceRole":"subagent","sourceSessionKey":"agent:lumi:subagent:abc"},"__openclaw":{"id":"h1"}},
     {"role":"user","content":"Result: 3 links","provenance":{"kind":"inter_session","sourceTool":"subagent_announce","sourceSessionKey":"agent:lumi:subagent:abc"},"__openclaw":{"id":"h2"}},
     {"role":"user","content":"run it","provenance":{"kind":"internal_system","sourceTool":"cron"},"__openclaw":{"id":"x1"}},
     {"role":"user","content":"from discord","provenance":{"kind":"external_user","sourceChannel":"discord"},"__openclaw":{"id":"x2"}}
    ]
    """)
    check(other[0].sender?.kind == .automation && other[0].role == .assistant, "cron run input is attributed to an automation")
    check(other[0].plainText == "Summarize the inbox", "cron sourcePromptPrefix is stripped (got \(other[0].plainText.debugDescription))")
    check(other[0].sender?.displayName(agents: agents) == "Automation", "unnamed cron → “Automation”")
    check(other[1].sender?.displayName(agents: agents) == "Weekly review", "Gateway label names the automation")
    check(other[1].sender?.canOpenSource == false, "a cron run isn't offered as a chat to open")
    check(other[2].sender?.kind == .helper && other[3].sender?.kind == .helper, "subagent messages and announcements → helper")
    check(other[2].sender?.displayName(agents: agents) == "Helper", "helper reads “Helper”")
    check(other[4].sender == nil && other[4].role == .user, "cron input without job/run/source stays a user turn (upstream rule)")
    check(other[5].sender == nil && other[5].via == "Discord", "external_user keeps the channel label")

    // Search and reply previews name the actual sender.
    let documents = MessageSearch.documents(sessionKey: "agent:lumi:main", items: projected)
    check(documents.map { $0.sender?.agentId } == ["kiko", nil, "kiko", nil, nil], "search documents carry the sender")
    check(projected[0].senderName(you: "You", agent: "Lumi", agents: agents) == "Kiko", "reply target names Kiko")
    check(projected[1].senderName(you: "You", agent: "Lumi", agents: agents) == "Lumi", "reply target to Lumi names Lumi")
    check(projected[4].senderName(you: "You", agent: "Lumi", agents: agents) == "You", "reply target to you names you")

    // Cached transcripts keep the sender.
    let encoded = try? JSONEncoder().encode(projected[0])
    let decoded = encoded.flatMap { try? JSONDecoder().decode(ChatItem.self, from: $0) }
    check(decoded?.sender == projected[0].sender, "sender survives the transcript cache")
}
