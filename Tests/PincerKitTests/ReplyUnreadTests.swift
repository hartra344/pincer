import Foundation
import Testing
@testable import PincerKit

/// #426: released Gateways (before openclaw/openclaw#155690) don't turn a chat unread when a reply
/// finishes, and since #374 the chat is read as the user sends. A reply that lands in a chat no
/// viewer shows must still mark it unread; one in a chat on screen (main window, split pane or a
/// chat window) must not.
@MainActor
@Suite("Reply unread")
struct ReplyUnreadTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    let open = "agent:main:dashboard:garden"
    let other = "agent:main:dashboard:trip"

    func demo(released: Bool = true) async -> GatewayStore {
        let gateway = GatewayStore(profile: GatewayProfile.demo(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        await gateway.connection.setDemoRepliesMarkUnread(!released)
        gateway.start()
        _ = await eventually(timeout: .seconds(10)) {
            gateway.state == .connected && gateway.sessions[self.open] != nil && gateway.sessions[self.other] != nil
        }
        return gateway
    }

    func finish(_ gateway: GatewayStore) async {
        gateway.stop()
        await TranscriptCache.shutdown(root: self.temp.url)
        self.temp.remove()
        self.scratch.remove()
    }

    /// Sends in `key` and waits until Pincer has decided what its reply means for unread.
    func reply(_ gateway: GatewayStore, in key: String) async -> Bool {
        let before = gateway.replyUnreadDecisions[key, default: 0]
        _ = await gateway.chat(for: key).send("hello")
        return await self.decided(gateway, key, after: before)
    }

    /// Waits for the reply-unread decision the store makes once a reply has landed (and its grace has run out).
    func decided(_ gateway: GatewayStore, _ key: String, after before: Int) async -> Bool {
        await eventually(timeout: .seconds(60)) { gateway.replyUnreadDecisions[key, default: 0] > before }
    }

    /// Only a safety net: it returns as soon as the row holds the value.
    func settled(_ gateway: GatewayStore, _ key: String, unread: Bool) async -> Bool {
        await eventually(timeout: .seconds(60)) { gateway.sessions[key]?.isUnread == unread }
    }

    func show(_ gateway: GatewayStore, _ key: String?) {
        if let key { gateway.selectedKey = key }
        gateway.setVisibleChat(key, viewer: GatewayStore.mainViewer)
    }

    @Test func replyInAChatNobodyIsViewingMarksItUnread() async {
        let gateway = await self.demo()
        self.show(gateway, self.open)
        #expect(await self.reply(gateway, in: self.other))
        #expect(await self.settled(gateway, self.other, unread: true), "a reply in a chat that isn't on screen is unread")
        #expect(gateway.totalUnread >= 1)
        #expect(await self.reply(gateway, in: self.open))
        #expect(gateway.sessions[self.open]?.isUnread == false, "the chat on screen stays read")
        await self.finish(gateway)
    }

    @Test func leavingAChatBeforeItsReplyLandsLeavesItUnread() async {
        let gateway = await self.demo()
        self.show(gateway, self.open)
        let before = gateway.replyUnreadDecisions[self.open, default: 0]
        _ = await gateway.chat(for: self.open).send("hello")
        // The user moves on while the reply is still coming.
        self.show(gateway, self.other)
        #expect(await self.decided(gateway, self.open, after: before))
        #expect(await self.settled(gateway, self.open, unread: true))
        self.show(gateway, self.open)
        #expect(await self.settled(gateway, self.open, unread: false), "coming back reads it")
        await self.finish(gateway)
    }

    @Test func replyWhileTheAppIsAwayIsUnread() async {
        let gateway = await self.demo()
        self.show(gateway, self.open)
        let before = gateway.replyUnreadDecisions[self.open, default: 0]
        _ = await gateway.chat(for: self.open).send("hello")
        self.show(gateway, nil)
        #expect(await self.decided(gateway, self.open, after: before))
        #expect(await self.settled(gateway, self.open, unread: true), "unread while away (#374)")
        self.show(gateway, self.open)
        #expect(await self.settled(gateway, self.open, unread: false))
        await self.finish(gateway)
    }

    @Test func splitPaneKeepsItsChatReadUntilItCloses() async {
        let gateway = await self.demo()
        self.show(gateway, self.open)
        gateway.chatWindowOpened(self.other)
        gateway.setVisibleChat(self.other, viewer: "split-1")
        #expect(await self.reply(gateway, in: self.other))
        #expect(gateway.sessions[self.other]?.isUnread == false, "the split pane's chat is on screen")
        gateway.setVisibleChat(nil, viewer: "split-1")
        gateway.chatWindowClosed(self.other)
        #expect(await self.reply(gateway, in: self.other))
        #expect(await self.settled(gateway, self.other, unread: true), "closed: its next reply is unread")
        await self.finish(gateway)
    }

    @Test func chatWindowKeepsItsChatReadUntilItCloses() async {
        let gateway = await self.demo()
        self.show(gateway, self.open)
        gateway.chatWindowOpened(self.other)
        gateway.setVisibleChat(self.other, viewer: "window-1")
        #expect(await self.reply(gateway, in: self.other))
        #expect(gateway.sessions[self.other]?.isUnread == false, "the chat window's chat is on screen")
        gateway.setVisibleChat(nil, viewer: "window-1")
        gateway.chatWindowClosed(self.other)
        #expect(await self.reply(gateway, in: self.other))
        #expect(await self.settled(gateway, self.other, unread: true))
        await self.finish(gateway)
    }

    @Test func switchingChatsReadsTheNewOneAndLeavesRepliesElsewhereUnread() async {
        let gateway = await self.demo()
        self.show(gateway, self.other)
        #expect(await self.reply(gateway, in: self.open))
        #expect(await self.settled(gateway, self.open, unread: true))
        self.show(gateway, self.open)
        #expect(await self.settled(gateway, self.open, unread: false))
        #expect(await self.reply(gateway, in: self.other))
        #expect(await self.settled(gateway, self.other, unread: true))
        await self.finish(gateway)
    }

    @Test func glancingAtTheReplyBeforeItIsMarkedReadsIt() async {
        let gateway = await self.demo()
        // Long enough that only glancing at the chat (which ends the wait) can resolve it.
        gateway.replyUnreadGrace = .seconds(45)
        self.show(gateway, self.open)
        let before = gateway.replyUnreadDecisions[self.other, default: 0]
        _ = await gateway.chat(for: self.other).send("hello")
        #expect(await eventually(timeout: .seconds(60)) { gateway.pendingReplyUnread.contains(self.other) })
        // Within the grace: open the chat, read the reply, go back.
        self.show(gateway, self.other)
        self.show(gateway, self.open)
        #expect(await self.decided(gateway, self.other, after: before))
        #expect(gateway.sessions[self.other]?.isUnread == false, "the user saw the reply")
        await self.finish(gateway)
    }

    @Test func onlyReadsBeforeTheReplyAreOverridden() {
        let replyAt = Date().timeIntervalSince1970 * 1000
        func row(_ fields: [String: JSONValue]) -> SessionRow {
            var raw = fields
            raw["key"] = raw["key"] ?? .string(self.other)
            return SessionRow(.object(raw))!
        }
        #expect(GatewayStore.shouldMarkReplyUnread(row: row(["unread": false, "lastReadAt": .number(replyAt - 5_000)]), replyAt: replyAt))
        #expect(GatewayStore.shouldMarkReplyUnread(row: row(["unread": false]), replyAt: replyAt))
        #expect(!GatewayStore.shouldMarkReplyUnread(row: row(["unread": false, "lastReadAt": .number(replyAt + 1_000)]), replyAt: replyAt),
                "another client read it after the reply")
        #expect(!GatewayStore.shouldMarkReplyUnread(row: row(["unread": true]), replyAt: replyAt), "the Gateway marked it already")
        #expect(!GatewayStore.shouldMarkReplyUnread(row: row(["key": "agent:main:subagent:x", "unread": false]), replyAt: replyAt))
    }

    @Test func currentGatewaysNeedNoPatch() async {
        let gateway = await self.demo(released: false)
        self.show(gateway, self.open)
        #expect(await self.reply(gateway, in: self.other))
        #expect(await self.settled(gateway, self.other, unread: true))
        await self.finish(gateway)
    }
}
