import Foundation
import Testing
@testable import PincerKit

/// The pure parts of message search. The SQLite index itself lives under the default cache root,
/// so it's covered by `PincerChecks`, which redirects that root.
@Suite("Message search")
struct MessageSearchTests {
    private func hit(_ key: String, _ id: String, _ text: String, at seconds: Double?) -> MessageSearch.Hit {
        MessageSearch.Hit(sessionKey: key, entryId: id, section: 0, role: .user,
                          timestamp: seconds.map { Date(timeIntervalSince1970: $0) }, text: text)
    }

    @Test func ftsQueryQuotesEveryWordAsAPrefix() {
        #expect(MessageSearch.ftsQuery("Tokyo ramen") == #""tokyo"* "ramen"*"#)
        #expect(MessageSearch.ftsQuery("Café") == #""cafe"*"#)
        #expect(MessageSearch.ftsQuery("a ramen") == #""ramen"*"#)
        #expect(MessageSearch.ftsQuery("NEAR(x AND -y*") == #""near"* "and"*"#)
        #expect(MessageSearch.ftsQuery("a") == nil)
        #expect(MessageSearch.ftsQuery("a b") == nil)
        #expect(MessageSearch.ftsQuery("  ") == nil)
    }

    @Test func foldingIgnoresCaseAndAccents() {
        #expect(MessageSearch.folded("CAFÉ Crème") == "cafe creme")
        #expect(MessageSearch.tokens("Déjà-vu, 2 fois!") == ["deja", "vu", "2", "fois"])
    }

    @Test func verifyUsesFindInChatMatching() {
        #expect(MessageSearch.verify(query: "cafe", markdown: "Meet at the **Café** at 9"))
        #expect(MessageSearch.verify(query: "tok", markdown: "Landing in Tokyo"))
        #expect(!MessageSearch.verify(query: "ramen tokyo", markdown: "Tokyo has great ramen"))
    }

    @Test func groupOrdersChatsByNewestHitAndCapsEach() {
        let hits = [
            self.hit("a", "1", "x", at: 10), self.hit("b", "2", "x", at: 30), self.hit("a", "3", "x", at: 20),
            self.hit("a", "4", "x", at: 5), self.hit("a", "5", "x", at: 1), self.hit("c", "6", "x", at: nil),
            self.hit("hidden", "7", "x", at: 99),
        ]
        let groups = MessageSearch.group(hits, allowed: ["a", "b", "c"], perChat: 3)
        #expect(groups.map(\.sessionKey) == ["b", "a", "c"])
        #expect(groups[1].hits.map(\.entryId) == ["3", "1", "4"] && groups[1].hasMore)
        #expect(!groups[0].hasMore)
        #expect(MessageSearch.group(hits, allowed: ["a", "b", "c"], maxChats: 1).map(\.sessionKey) == ["b"])
    }

    @Test func collectDropsUnverifiedCandidates() {
        let candidates = [
            self.hit("a", "1", "Tokyo has great ramen", at: 3),
            self.hit("b", "2", "ramen in Tokyo", at: 2),
        ]
        let groups = MessageSearch.collect(candidates, query: "ramen in", allowed: ["a", "b"])
        #expect(groups.map(\.sessionKey) == ["b"])
    }

    @Test func snippetCutsAroundTheFirstMatch() {
        let short = MessageSearch.snippet(query: "café", markdown: "Meet at the café")
        #expect(short.text == "Meet at the café" && short.highlights == [NSRange(location: 12, length: 4)])
        let long = String(repeating: "filler words here ", count: 20) + "the needle is here " + String(repeating: "tail ", count: 40)
        let cut = MessageSearch.snippet(query: "needle", markdown: long, maxLength: 60)
        #expect(cut.text.hasPrefix("…") && cut.text.hasSuffix("…"))
        #expect((cut.text as NSString).length <= 60)
        #expect(cut.highlights.count == 1)
    }

    @Test func documentsCoverUserAndAssistantTextOnly() {
        let items: [ChatItem] = [
            ChatItem(id: "u1", role: .user, blocks: [.text("Where should we eat?")], timestamp: Date(timeIntervalSince1970: 1)),
            ChatItem(id: "a1", role: .assistant, blocks: [.thinking("secret plan"), .text("Try the ramen place")],
                     timestamp: Date(timeIntervalSince1970: 2)),
        ]
        let documents = MessageSearch.documents(sessionKey: "k", items: items)
        #expect(documents.map(\.role) == [.user, .assistant])
        #expect(documents.map(\.text) == ["Where should we eat?", "Try the ramen place"])
        #expect(documents.allSatisfy { $0.sessionKey == "k" })
    }
}
