import Foundation
import Testing
@testable import PincerKit

/// Cached transcripts from before #207 get their inter-session turns attributed on load.
@Suite("Forwarded sender cache migration")
struct ForwardedSenderMigrationTests {
    static let header = "[Inter-session message] sourceSession=agent:kiko:main sourceChannel=internal sourceTool=sessions_send isUser=false"

    func v5File(_ items: [ChatItem]) throws -> Data {
        try JSONEncoder().encode(TranscriptCache.Snapshot(version: 5, items: items, complete: true))
    }

    @Test func interSessionTurnBecomesTheSendersMessage() throws {
        var forwarded = ChatItem(id: "f1", role: .user, blocks: [.text("\(Self.header)\n\(MessageSender.interSessionPromptExplanation)\nHi Lumi!")])
        forwarded.transcriptId = "f1"
        let own = ChatItem(id: "u1", role: .user, blocks: [.text("thanks")])
        let reply = ChatItem(id: "a1", role: .assistant, blocks: [.text("Hi Kiko!")])
        let (snapshot, outcome) = TranscriptCache.decode(try self.v5File([forwarded, reply, own]))
        #expect(outcome == .migrated(from: 5))
        let items = try #require(snapshot?.items)
        #expect(snapshot?.version == TranscriptCache.Snapshot.currentVersion)
        #expect(items[0].role == .assistant && items[0].sender == MessageSender(kind: .agent, sessionKey: "agent:kiko:main"))
        #expect(items[0].plainText == "Hi Lumi!" && items[0].transcriptId == "f1")
        #expect(items[1].sender == nil && items[1].plainText == "Hi Kiko!")
        #expect(items[2].role == .user && items[2].sender == nil && items[2].plainText == "thanks")
        let turns = TranscriptBuilder.build(items).compactMap { if case let .assistant(turn) = $0 { turn } else { nil } }
        #expect(turns.map { $0.sender?.agentId } == ["kiko", nil])
    }

    @Test func otherInterSessionToolsStayAsTheyWere() throws {
        let header = "[Inter-session message] sourceSession=agent:lumi:main sourceTool=exec_approval_followup isUser=false\nok"
        let item = ChatItem(id: "x", role: .user, blocks: [.text(header)])
        let (snapshot, _) = TranscriptCache.decode(try self.v5File([item]))
        #expect(snapshot?.items.first?.role == .user && snapshot?.items.first?.sender == nil)
    }

    @Test func subagentHeaderIsAHelper() throws {
        let text = "[Inter-session message] sourceSession=agent:lumi:subagent:abc sourceTool=subagent_announce isUser=false\nDone"
        let (snapshot, _) = TranscriptCache.decode(try self.v5File([ChatItem(id: "h", role: .user, blocks: [.text(text)])]))
        #expect(snapshot?.items.first?.sender?.kind == .helper && snapshot?.items.first?.plainText == "Done")
    }
}
