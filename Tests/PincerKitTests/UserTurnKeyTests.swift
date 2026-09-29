import Foundation
import Testing
@testable import PincerKit

/// #429: the Gateway stores a sent user turn under `<clientKey>:user`; Pincer matches on the bare key.
@MainActor
@Suite("User turn idempotency keys")
struct UserTurnKeyTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()

    static func message(_ key: String, text: String = "hi", id: String = "m1") -> JSONValue {
        Fixtures.json("""
        {"role":"user","content":[{"type":"text","text":"\(text)"}],"__openclaw":{"id":"\(id)","idempotencyKey":"\(key)"}}
        """)
    }

    @Test func stripsTheUserTurnSuffix() {
        #expect(ChatItem(Self.message("abc-123:user"), fallbackIndex: 0)?.idempotencyKey == "abc-123")
        #expect(ChatItem(Self.message("abc-123"), fallbackIndex: 0)?.idempotencyKey == "abc-123")
        #expect(ChatItem(Self.message(":user"), fallbackIndex: 0)?.idempotencyKey == ":user")
        #expect(ChatItem(Self.message("a:user:user"), fallbackIndex: 0)?.idempotencyKey == "a:user")
        let topLevel = Fixtures.json(#"{"role":"user","content":"hi","idempotencyKey":"k9:user"}"#)
        #expect(ChatItem(topLevel, fallbackIndex: 0)?.idempotencyKey == "k9")
    }

    @Test func aReloadedHistoryCommitsThePendingSend() async {
        let gateway = GatewayStore(profile: GatewayProfile.demo(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        let chat = gateway.chat(for: "agent:main:main")
        chat.items = [ChatItem(role: .user, blocks: [.text("edited")], timestamp: Date(), idempotencyKey: "k1", isPending: true)]
        let messages = [Self.message("k1:user", text: "edited")]
        chat.apply(history: .object(["messages": .array(messages)]), parsed: ChatStore.parse(messages))
        #expect(!chat.items.contains { $0.isPending }, "the reload replaces the pending row")
        #expect(chat.items.count == 1 && chat.items.first?.transcriptId == "m1")
        await TranscriptCache.shutdown(root: self.temp.url)
        self.temp.remove()
        self.scratch.remove()
    }
}
