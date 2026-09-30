import Foundation
import Testing
@testable import PincerKit

/// #110: assistant reply targets (`openclawDelivery`, `[[reply_to…]]` directives) and how they resolve to quotes.
@MainActor
@Suite("Reply targets")
struct ReplyTargetTests {
    static func item(_ text: String) -> ChatItem {
        ChatItem(Fixtures.json(text), fallbackIndex: 0)!
    }

    static func assistant(_ id: String, _ text: String = "answer", delivery: String? = nil, structured: String? = nil) -> ChatItem {
        let delivery = delivery.map { #","openclawDelivery":\#($0)"# } ?? ""
        let structured = structured.map { #","replyToId":"\#($0)""# } ?? ""
        return Self.item(#"{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]\#(delivery),"__openclaw":{"id":"\#(id)"\#(structured)}}"#)
    }

    static func user(_ id: String, _ text: String = "question", channelId: String? = nil) -> ChatItem {
        let transport = channelId.map { #","transport":{"channel":"telegram","messageId":"\#($0)"}"# } ?? ""
        return Self.item(#"{"role":"user","content":[{"type":"text","text":"\#(text)"}],"__openclaw":{"id":"\#(id)"\#(transport)}}"#)
    }

    /// A chat holds its gateway weakly.
    static var gateways: [GatewayStore] = []

    func chat(_ items: [ChatItem], row: String? = nil) -> ChatStore {
        let suite = "ReplyTargetTests.\(UUID().uuidString)"
        let profile = GatewayProfile(id: UUID(), name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: UserDefaults(suiteName: suite)!, identity: Fixtures.identity())
        Self.gateways.append(gateway)
        let chat = ChatStore(sessionKey: "agent:main:main", agentId: nil, gateway: gateway, headless: true)
        if let row { gateway.setSession(SessionRow(Fixtures.json(row)), for: "agent:main:main") }
        chat.items = items
        chat.rebuild(itemsChanged: true)
        return chat
    }

    // MARK: Parsing

    @Test func deliveryReplyToIdParses() {
        let a = Self.assistant("a1", delivery: #"{"replyToId":"  u1  "}"#)
        #expect(a.replyToId == "u1" && a.replyToCurrent == false)
    }

    @Test func deliveryReplyToCurrentParses() {
        let a = Self.assistant("a1", delivery: #"{"replyToCurrent":true}"#)
        #expect(a.replyToCurrent && a.replyToId == nil)
        #expect(Self.assistant("a2", delivery: #"{"replyToCurrent":false}"#).replyToCurrent == false)
        #expect(Self.assistant("a3", delivery: #"{"audioAsVoice":true}"#).replyToCurrent == false)
    }

    @Test func blankDeliveryReplyToIdIsNil() {
        #expect(Self.assistant("a1", delivery: #"{"replyToId":"   "}"#).replyToId == nil)
        #expect(Self.assistant("a2", delivery: #"{"replyToId":""}"#).replyToId == nil)
    }

    @Test func structuredReplyToIdWinsOverDelivery() {
        let a = Self.assistant("a1", delivery: #"{"replyToId":"delivery"}"#, structured: "structured")
        #expect(a.replyToId == "structured")
    }

    @Test func deliveryIsNotReadOnUserMessages() {
        let u = Self.item(#"{"role":"user","content":[{"type":"text","text":"x"}],"openclawDelivery":{"replyToId":"a1","replyToCurrent":true},"__openclaw":{"id":"u1"}}"#)
        #expect(u.replyToId == nil && u.replyToCurrent == false)
    }

    @Test func plainAssistantHasNoTarget() {
        let a = Self.assistant("a1")
        #expect(a.replyToId == nil && a.replyToCurrent == false)
    }

    @Test func replyFieldsSurviveCoding() throws {
        for a in [Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#), Self.assistant("a2", delivery: #"{"replyToCurrent":true}"#)] {
            let decoded = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(a))
            #expect(decoded == a && decoded.replyToId == a.replyToId && decoded.replyToCurrent == a.replyToCurrent)
        }
    }

    @Test func transcriptCacheVersionBumpedForReplyTargets() {
        #expect(TranscriptCache.Snapshot.currentVersion > 8)
    }

    // MARK: Directives

    @Test func extractsDirectives() {
        let byId = Replies.extractDirective("[[reply_to:abc-123]] Recovered answer")
        #expect(byId.target == .id("abc-123") && byId.text.trimmingCharacters(in: .whitespaces) == "Recovered answer")
        let current = Replies.extractDirective("[[reply_to_current]] Ready")
        #expect(current.target == .current && current.text.trimmingCharacters(in: .whitespaces) == "Ready")
    }

    @Test func directiveWhitespaceVariants() {
        let spaced = Replies.extractDirective("[[ reply_to : 123 ]]ok")
        #expect(spaced.target == .id("123") && spaced.text == "ok")
        #expect(Replies.extractDirective("[[ reply_to_current ]]ok").target == .current)
        let lines = Replies.extractDirective("[[reply_to:\nid\n ]]Visible reply")
        #expect(lines.target == .id("id") && lines.text == "Visible reply")
    }

    @Test func directiveInTheMiddleOfText() {
        let r = Replies.extractDirective("hello [[reply_to_current]] world")
        #expect(r.target == .current && !r.text.contains("[["))
        #expect(r.text.contains("hello") && r.text.contains("world"))
    }

    @Test func plainTextIsUntouched() {
        let input = "  keep leading and trailing whitespace  "
        let r = Replies.extractDirective(input)
        #expect(r.target == nil && r.text == input)
    }

    @Test func malformedDirectivesStayLiteral() {
        for input in ["[[reply_to:message-7 Visible reply", "Visible reply\n[[reply_to_current] literally", "[[reply_to:]] x"] {
            let r = Replies.extractDirective(input)
            #expect(r.target == nil, "\(input)")
        }
        #expect(Replies.extractDirective("[[reply_to:message-7 Visible reply").text == "[[reply_to:message-7 Visible reply")
    }

    @Test func directivesInCodeStayLiteral() {
        let input = "Use `[[reply_to_current]]` literally.\n```text\n[[reply_to:example-id]]\n```"
        let r = Replies.extractDirective(input)
        #expect(r.target == nil && r.text == input)
    }

    @Test func unrelatedDoubleBracketsStayLiteral() {
        let r = Replies.extractDirective("see [[wiki link]] and [[reply_toX]]")
        #expect(r.target == nil && r.text == "see [[wiki link]] and [[reply_toX]]")
    }

    @Test func leakedDirectiveIsStrippedAndSuppliesTarget() {
        let a = Self.assistant("a1", "[[reply_to:u1]] Here you go")
        #expect(a.plainText.trimmingCharacters(in: .whitespaces) == "Here you go" && a.replyToId == "u1")
        let c = Self.assistant("a2", "[[reply_to_current]] Ready")
        #expect(c.plainText.trimmingCharacters(in: .whitespaces) == "Ready" && c.replyToCurrent)
    }

    @Test func deliveryAndStructuredBeatDirective() {
        let a = Self.assistant("a1", "[[reply_to:leaked]] Hi", delivery: #"{"replyToId":"delivery"}"#)
        #expect(a.replyToId == "delivery" && !a.plainText.contains("[["))
        let b = Self.assistant("a2", "[[reply_to:leaked]] Hi", structured: "structured")
        #expect(b.replyToId == "structured")
    }

    @Test func directivesAreNotStrippedFromUserText() {
        let u = Self.user("u1", "please write [[reply_to_current]] in docs")
        #expect(u.plainText.contains("[[reply_to_current]]") && u.replyToId == nil)
    }

    // MARK: Resolution

    @Test func targetResolvesByTranscriptId() throws {
        let store = self.chat([Self.user("u1", "disk?"), Self.assistant("a1", "40% used"), Self.user("u2", "and memory?"),
                               Self.assistant("a2", "late answer", delivery: #"{"replyToId":"u1"}"#)])
        let quote = try #require(store.quote(for: store.items[3]))
        #expect(quote.targetId == "u1" && quote.sender == .you && quote.text == "disk?")
    }

    @Test func targetResolvesByChannelMessageId() throws {
        let store = self.chat([Self.user("u1", "disk?", channelId: "9001"), Self.user("u2", "and memory?", channelId: "9002"),
                               Self.assistant("a1", "late answer", delivery: #"{"replyToId":"9001"}"#)])
        let quote = try #require(store.quote(for: store.items[2]))
        #expect(quote.text == "disk?" && quote.sender == .you)
    }

    @Test func channelIdOfAnAssistantItemDoesNotResolve() throws {
        // Only user items carry the channel's own message id.
        let store = self.chat([Self.user("u1", "q"), Self.assistant("a1", "one"), Self.user("u2", "q2"), Self.assistant("a2", "two", delivery: #"{"replyToId":"nope"}"#)])
        let quote = try #require(store.quote(for: store.items[3]))
        #expect(quote.text == nil)
    }

    @Test func replyToCurrentDirectlyAnsweringRendersNoQuote() {
        let store = self.chat([Self.user("u1"), Self.assistant("a1", delivery: #"{"replyToCurrent":true}"#)])
        #expect(store.quote(for: store.items[1]) == nil)
    }

    @Test func replyToCurrentSkipsToolAndAssistantItems() {
        let store = self.chat([Self.user("u1"), Self.assistant("a0", "working"), Self.assistant("a1", delivery: #"{"replyToCurrent":true}"#)])
        #expect(store.quote(for: store.items[2]) == nil)
    }

    @Test func replyToIdOfTheDirectlyAnsweredMessageRendersNoQuote() {
        let store = self.chat([Self.user("u0"), Self.assistant("a0"), Self.user("u1"), Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#)])
        #expect(store.quote(for: store.items[3]) == nil)
        let byChannel = self.chat([Self.user("u1", channelId: "77"), Self.assistant("a1", delivery: #"{"replyToId":"77"}"#)])
        #expect(byChannel.quote(for: byChannel.items[1]) == nil)
    }

    @Test func quotesAnEarlierMessageWhenAnotherUserMessageIntervenes() throws {
        let store = self.chat([Self.user("u1", "first"), Self.user("u2", "second"), Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#)])
        let quote = try #require(store.quote(for: store.items[2]))
        #expect(quote.targetId == "u1" && quote.text == "first")
    }

    @Test func bridgedSenderNamesTheQuote() throws {
        let maya = Self.item(#"{"role":"user","content":[{"type":"text","text":"first"}],"senderLabel":"Maya (0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0)","__openclaw":{"id":"u1","senderName":"Maya B"}}"#)
        let store = self.chat([maya, Self.user("u2", "second"), Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#)])
        let quote = try #require(store.quote(for: store.items[2]))
        #expect(quote.sender == .label("Maya"))
        #expect(maya.senderName(you: "You", agent: "Lumi", agents: []) == "Maya")
    }

    @Test func bridgedSenderFallsBackToOpenclawNameThenUsername() {
        let named = Self.item(#"{"role":"user","content":[{"type":"text","text":"a"}],"__openclaw":{"id":"u1","senderName":" Maya ","senderUsername":"maya_b"}}"#)
        let username = Self.item(#"{"role":"user","content":[{"type":"text","text":"b"}],"__openclaw":{"id":"u2","senderUsername":"maya_b"}}"#)
        #expect(named.channelSenderName == "Maya" && username.channelSenderName == "maya_b")
        #expect(Self.user("u3").channelSenderName == nil && Self.assistant("a1").channelSenderName == nil)
    }

    @Test func unresolvedIdStillQuotes() throws {
        let store = self.chat([Self.user("u1"), Self.assistant("a1", delivery: #"{"replyToId":"gone-42"}"#)])
        let quote = try #require(store.quote(for: store.items[1]))
        #expect(quote.targetId == "gone-42" && quote.text == nil)
    }

    @Test func assistantTargetingAnAssistantMessageQuotesIt() throws {
        let store = self.chat([Self.user("u1"), Self.assistant("a1", "the plan"), Self.user("u2"), Self.assistant("a2", "again", delivery: #"{"replyToId":"a1"}"#)])
        let quote = try #require(store.quote(for: store.items[3]))
        #expect(quote.targetId == "a1" && quote.text == "the plan" && quote.sender == .agent)
    }

    @Test func assistantWithoutTargetHasNoQuote() {
        let store = self.chat([Self.user("u1"), Self.assistant("a1")])
        #expect(store.quote(for: store.items[1]) == nil)
    }

    @Test func leakedDirectiveDrivesTheQuote() throws {
        let store = self.chat([Self.user("u1", "first"), Self.user("u2", "second"), Self.assistant("a1", "[[reply_to:u1]] done")])
        let quote = try #require(store.quote(for: store.items[2]))
        #expect(quote.targetId == "u1" && quote.text == "first")
    }

    @Test func userQuotesStillWork() throws {
        let store = self.chat([Self.assistant("a1", "Disk status"),
                               Self.item(#"{"role":"user","content":[{"type":"text","text":"that"}],"__openclaw":{"id":"u1","replyToId":"a1"}}"#)])
        let quote = try #require(store.quote(for: store.items[1]))
        #expect(quote.targetId == "a1" && quote.text == "Disk status" && quote.sender == .agent)
    }

    static func webchatUser(_ id: String, _ text: String, key: String) -> ChatItem {
        Self.item(#"{"role":"user","content":[{"type":"text","text":"\#(text)"}],"__openclaw":{"id":"\#(id)","idempotencyKey":"\#(key)"}}"#)
    }

    @Test func targetResolvesByUserIdempotencyKey() throws {
        // Webchat: the model types the run's client id; the user entry is stored as "<runId>:user".
        let store = self.chat([Self.webchatUser("u1", "disk?", key: "run-1:user"), Self.webchatUser("u2", "memory?", key: "run-2:user"),
                               Self.assistant("a1", "late", delivery: #"{"replyToId":"run-1"}"#)])
        let quote = try #require(store.quote(for: store.items[2]))
        #expect(quote.targetId == "u1" && quote.text == "disk?" && quote.sender == .you)
    }

    @Test func idempotencyKeyOfTheAnsweredMessageRendersNoQuote() {
        let store = self.chat([Self.webchatUser("u1", "disk?", key: "run-1:user"), Self.assistant("a1", delivery: #"{"replyToId":"run-1"}"#)])
        #expect(store.quote(for: store.items[1]) == nil)
    }

    @Test func transcriptIdWinsOverIdempotencyKey() throws {
        let store = self.chat([Self.webchatUser("u1", "first", key: "shared:user"), Self.user("shared", "second"), Self.user("u3"),
                               Self.assistant("a1", delivery: #"{"replyToId":"shared"}"#)])
        let quote = try #require(store.quote(for: store.items[3]))
        #expect(quote.targetId == "shared" && quote.text == "second")
    }

    // MARK: Shape of a transcript id, groups

    @Test func transcriptIdShapes() {
        for id in ["12345678", "0f3cA9bD", "8D0E8F2A-6B1F-4B6E-9E0C-1A2B3C4D5E6F"] { #expect(ChatStore.looksLikeTranscriptId(id), "\(id)") }
        for id in ["7421093845", "1234567", "123456789", "abcdefgh", "9101", "", "chan-1", "run-1"] { #expect(!ChatStore.looksLikeTranscriptId(id), "\(id)") }
    }

    @Test func quoteTapOnAChannelMessageIdFailsFastWithANotice() async {
        let store = self.chat([Self.user("u1")])
        let found = await store.locateReplyTarget("7421093845")
        #expect(!found && store.locatingReplyId == nil && store.notice == "The original message isn't in this chat's history anymore.")
        #expect(store.items.count == 1)
    }

    @Test func quoteTapOnALoadedIdNeedsNoPaging() async {
        let store = self.chat([Self.user("12345678")])
        #expect(await store.locateReplyTarget("12345678") && store.notice == nil)
    }

    @Test func plainLocateStillPagesForAnyId() async {
        // Only quote taps are gated on the id's shape; other callers (search, links) page for any id.
        let store = self.chat([Self.user("u1")])
        _ = await store.locate("7421093845")
        #expect(store.notice != nil && store.locatingReplyId == nil)
    }

    @Test func groupChatsKeepTheQuoteOfTheAnsweredMessage() throws {
        for row in [#"{"key":"agent:main:main","chatType":"group"}"#, #"{"key":"agent:main:main","chatType":"channel"}"#] {
            let store = self.chat([Self.user("u1", "disk?"), Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#)], row: row)
            let quote = try #require(store.quote(for: store.items[1]), Comment(rawValue: row))
            #expect(quote.targetId == "u1" && quote.text == "disk?")
        }
    }

    @Test func directChatsAndUnknownSessionsKeepTheNoiseRule() {
        let direct = self.chat([Self.user("u1"), Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#)], row: #"{"key":"agent:main:main","chatType":"direct"}"#)
        #expect(direct.quote(for: direct.items[1]) == nil)
        let unknown = self.chat([Self.user("u1"), Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#)])
        #expect(unknown.quote(for: unknown.items[1]) == nil)
    }

    // MARK: Transcript cache

    @Test func cacheRoundTripsReplyTargets() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let id = UUID()
        let items = [Self.user("u1"), Self.assistant("a1", delivery: #"{"replyToId":"u1"}"#), Self.assistant("a2", delivery: #"{"replyToCurrent":true}"#)]
        let snapshot = TranscriptCache.Snapshot(items: items, complete: true)
        await TranscriptCache.save(snapshot, gatewayId: id, sessionKey: "agent:main:main", root: temp.url)
        await TranscriptCache.flush(gatewayId: id, root: temp.url)
        let loaded = try #require(await TranscriptCache.load(gatewayId: id, sessionKey: "agent:main:main", root: temp.url))
        #expect(loaded.items.map(\.replyToId) == [nil, "u1", nil] && loaded.items.map(\.replyToCurrent) == [false, false, true])
        await TranscriptCache.shutdown(root: temp.url)
    }
}
