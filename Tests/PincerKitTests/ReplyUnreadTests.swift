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

    /// Sends in `key` and waits for the demo's reply to finish.
    func reply(_ gateway: GatewayStore, in key: String) async -> Bool {
        let chat = gateway.chat(for: key)
        _ = await chat.send("hello")
        return await self.finished(gateway, key)
    }

    func finished(_ gateway: GatewayStore, _ key: String) async -> Bool {
        try? await Task.sleep(for: .milliseconds(200))
        return await eventually(timeout: .seconds(20)) {
            !gateway.chat(for: key).isRunning && gateway.sessions[key]?.hasActiveRun == false
        }
    }

    func settled(_ gateway: GatewayStore, _ key: String, unread: Bool) async -> Bool {
        await eventually(timeout: .seconds(10)) { gateway.sessions[key]?.isUnread == unread }
    }

    /// Unread holds for a while, past the grace before Pincer marks a reply.
    func stays(_ gateway: GatewayStore, _ key: String, unread: Bool) async -> Bool {
        try? await Task.sleep(for: GatewayStore.replyUnreadGrace + .milliseconds(800))
        return gateway.sessions[key]?.isUnread == unread
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
        #expect(await self.stays(gateway, self.open, unread: false), "the chat on screen stays read")
        await self.finish(gateway)
    }

    @Test func leavingAChatBeforeItsReplyLandsLeavesItUnread() async {
        let gateway = await self.demo()
        self.show(gateway, self.open)
        _ = await gateway.chat(for: self.open).send("hello")
        // The user moves on while the reply is still coming.
        self.show(gateway, self.other)
        #expect(await self.finished(gateway, self.open))
        #expect(await self.settled(gateway, self.open, unread: true))
        self.show(gateway, self.open)
        #expect(await self.settled(gateway, self.open, unread: false), "coming back reads it")
        await self.finish(gateway)
    }

    @Test func replyWhileTheAppIsAwayIsUnread() async {
        let gateway = await self.demo()
        self.show(gateway, self.open)
        _ = await gateway.chat(for: self.open).send("hello")
        self.show(gateway, nil)
        #expect(await self.finished(gateway, self.open))
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
        #expect(await self.stays(gateway, self.other, unread: false), "the split pane's chat is on screen")
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
        #expect(await self.stays(gateway, self.other, unread: false), "the chat window's chat is on screen")
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
        let saved = GatewayStore.replyUnreadGrace
        GatewayStore.replyUnreadGrace = .seconds(3)
        defer { GatewayStore.replyUnreadGrace = saved }
        let gateway = await self.demo()
        self.show(gateway, self.open)
        #expect(await self.reply(gateway, in: self.other))
        // Within the grace: open the chat, read the reply, go back.
        self.show(gateway, self.other)
        self.show(gateway, self.open)
        try? await Task.sleep(for: .seconds(4))
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
