import Foundation
import Testing
@testable import PincerKit

@Suite("Replies and reactions")
struct ReactionsReplyTests {
    static func item(_ text: String) -> ChatItem {
        ChatItem(Fixtures.json(text), fallbackIndex: 0)!
    }

    @Test func replyAndTransportFactsSurviveCoding() throws {
        let item = Self.item(#"""
        {"role":"user","content":[{"type":"text","text":"that"}],"__openclaw":{"id":"u1","replyToId":"a1",
         "replyToPreview":{"text":"Disk status","senderLabel":"Claw"},
         "transport":{"channel":"discord","messageId":"1300","conversationRef":"channel:123"}}}
        """#)
        let decoded = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
        #expect(decoded.replyToId == "a1" && decoded.replyToPreview == ReplyPreview(text: "Disk status", senderLabel: "Claw"))
        #expect(decoded.channelMessageId == "1300" && decoded.transportChannel == "discord" && decoded.conversationRef == "channel:123")
    }

    @Test func cachedItemsWithoutTheNewFieldsDecode() throws {
        var plain = Self.item(#"{"role":"user","content":[{"type":"text","text":"x"}],"__openclaw":{"id":"u1"}}"#)
        plain.replyToId = nil
        let data = try JSONEncoder().encode(plain)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["replyToId", "replyToPreview", "channelMessageId", "transportChannel", "conversationRef"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(ChatItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.replyToId == nil && decoded.channelMessageId == nil && decoded.plainText == "x")
    }

    /// Caches from before reply and transport facts (version 4) are refetched.
    @Test func transcriptCacheVersionBumped() {
        #expect(TranscriptCache.Snapshot.currentVersion > 4)
    }

    @Test func unsupportedForwardingErrors() {
        #expect(Reactions.isUnsupported(GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)))
        #expect(Reactions.isUnsupported(GatewayError.rpc(code: "INVALID_REQUEST", message: "bad", details: nil)))
        #expect(Reactions.isUnsupported(GatewayError.rpc(code: "UNAVAILABLE", message: "Reactions not supported here", details: nil)))
        #expect(Reactions.isUnsupported(GatewayError.rpc(code: "ERROR", message: "Unknown action: react", details: nil)))
        #expect(!Reactions.isUnsupported(GatewayError.rpc(code: "UNAVAILABLE", message: "discord is down", details: nil)))
        #expect(!Reactions.isUnsupported(GatewayError.timeout("message.action")))
    }

    @Test func recentEmojiPersistInDefaults() {
        let name = "pincer-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Reactions.recent(in: defaults).isEmpty)
        for emoji in ["👍", "🎉", "👍", "1", "2", "3", "4", "5", "6", "7"] { Reactions.noteRecent(emoji, defaults: defaults) }
        #expect(Reactions.recent(in: defaults) == ["7", "6", "5", "4", "3", "2", "1", "👍"])
    }

    /// AC-33: no invented gateway methods. Every method Pincer calls is a known one; reactions
    /// only ever go through `message.action`.
    @Test func noInventedGatewayMethods() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let forbidden = ["reactions.", "chat.react", "message.react", "session.message.reaction", "reaction.add", "reaction.remove"]
        let call = /request\(\s*"([A-Za-z0-9_.\-]+)"/
        var called: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: call) { called.insert(String(match.1)) }
            for method in forbidden {
                #expect(!text.contains("\"\(method)"), "\(file.lastPathComponent) mentions \(method)")
            }
        }
        #expect(called.contains("message.action") && called.contains("chat.send"))
        #expect(!called.contains { $0.localizedCaseInsensitiveContains("react") })
    }
}
