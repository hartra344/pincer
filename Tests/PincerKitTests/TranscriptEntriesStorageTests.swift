import Foundation
import Testing
@testable import PincerKit

/// #315: a chat keeps one copy of its transcript entries (committed entries plus the live tail in `entries`).
@MainActor
@Suite("Transcript entries storage", .serialized)
struct TranscriptEntriesStorageTests {
    let scratch = ScratchDefaults()
    static let key = "agent:entries:main"

    func chat() -> ChatStore {
        GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                     defaults: self.scratch.defaults, identity: Fixtures.identity()).chat(for: Self.key)
    }

    static func items(_ count: Int) -> [ChatItem] {
        (0..<count).map { n in
            ChatItem(id: "m\(n)", role: n.isMultiple(of: 2) ? .user : .assistant, blocks: [.text("message \(n)")],
                     timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
        }
    }

    func delta(_ chat: ChatStore, _ full: String) {
        chat.handleChat(["runId": "run_1", "sessionKey": .string(Self.key), "state": "delta",
                         "message": ["role": "assistant", "content": .array([["type": "text", "text": .string(full)]])]])
    }

    @Test func storesNoSecondTranscriptArray() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        chat.items = Self.items(6)
        let arrays = Mirror(reflecting: chat).children.filter { ($0.value as? [TranscriptEntry])?.isEmpty == false }
        #expect(arrays.count == 1, "only `entries` holds transcript entries: \(arrays.map(\.label))")
    }

    @Test func streamingReplacesOnlyTheLiveTail() async {
        defer { self.scratch.remove() }
        let saved = ChatStore.liveFlushInterval
        ChatStore.liveFlushInterval = 0
        defer { ChatStore.liveFlushInterval = saved }
        let chat = self.chat()
        chat.items = Self.items(6)
        let committed = TranscriptBuilder.build(chat.items)
        #expect(chat.entries == committed)
        #expect(chat.committedEntryCount == committed.count)

        self.delta(chat, "Hel")
        self.delta(chat, "Hello")
        chat.flushLive()
        #expect(Array(chat.entries.prefix(committed.count)) == committed)
        #expect(chat.entries.count == committed.count + 1)
        guard case let .assistant(turn) = chat.entries.last else { Issue.record("no live turn"); return }
        #expect(turn.isStreaming && turn.body == "Hello")

        // New committed items rebuild the prefix and keep the live tail after it.
        chat.items += Self.items(8).suffix(2)
        let rebuilt = TranscriptBuilder.build(chat.items)
        #expect(Array(chat.entries.prefix(rebuilt.count)) == rebuilt)
        #expect(chat.committedEntryCount == rebuilt.count)
        #expect(chat.entries.count == rebuilt.count + 1)

        chat.live = nil
        chat.rebuild(itemsChanged: false)
        #expect(chat.entries == rebuilt)
    }
}
