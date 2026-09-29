import Foundation
import Testing
@testable import PincerKit

/// #374: a message that lands in the chat the user is looking at is read straight away; one that
/// lands while the app is in the background stays unread until the chat is on screen again.
@MainActor
@Suite("Visible chat read")
struct VisibleChatReadTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    let open = "agent:main:dashboard:garden"
    let other = "agent:main:dashboard:trip"

    func demo() async -> GatewayStore {
        let gateway = GatewayStore(profile: GatewayProfile.demo(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
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

    /// Marks `key` unread the way a finished run does and waits for the change to arrive.
    func arrive(_ gateway: GatewayStore, _ key: String) async {
        await gateway.patch(key, ["unread": true])
    }

    func settled(_ gateway: GatewayStore, _ key: String, unread: Bool) async -> Bool {
        await eventually(timeout: .seconds(15)) { gateway.sessions[key]?.isUnread == unread }
    }

    @Test func arrivingInTheVisibleChatMarksItRead() async {
        let gateway = await self.demo()
        #expect(gateway.state == .connected)
        gateway.setVisibleChat(self.open, viewer: GatewayStore.mainViewer)
        #expect(gateway.visibleChatKeys == [self.open])

        await self.arrive(gateway, self.open)
        await self.arrive(gateway, self.other)
        // Changes arrive in order, so once the other chat reads unread, the open one's change has landed too.
        #expect(await self.settled(gateway, self.other, unread: true), "another chat stays unread")
        #expect(await self.settled(gateway, self.open, unread: false), "the chat on screen is read at once")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gateway.sessions[self.other]?.isUnread == true)
        await self.finish(gateway)
    }

    @Test func arrivingInTheBackgroundWaitsUntilTheChatIsVisibleAgain() async {
        let gateway = await self.demo()
        gateway.setVisibleChat(self.open, viewer: GatewayStore.mainViewer)
        // The app goes to the background (or the window loses focus) with the chat still selected.
        gateway.setVisibleChat(nil, viewer: GatewayStore.mainViewer)
        #expect(gateway.visibleChatKeys.isEmpty)

        await self.arrive(gateway, self.open)
        #expect(await self.settled(gateway, self.open, unread: true))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gateway.sessions[self.open]?.isUnread == true, "unread while away, so it still notifies")

        gateway.setVisibleChat(self.open, viewer: GatewayStore.mainViewer)
        #expect(await self.settled(gateway, self.open, unread: false), "read once the app is active again")
        await self.finish(gateway)
    }

    @Test func anyViewerCounts() async {
        let gateway = await self.demo()
        gateway.setVisibleChat(self.open, viewer: GatewayStore.mainViewer)
        gateway.setVisibleChat(self.other, viewer: "window-1")
        #expect(gateway.visibleChatKeys == [self.open, self.other])
        gateway.setVisibleChat(nil, viewer: GatewayStore.mainViewer)
        await self.arrive(gateway, self.other)
        await self.arrive(gateway, self.open)
        #expect(await self.settled(gateway, self.open, unread: true))
        #expect(await self.settled(gateway, self.other, unread: false), "a chat shown in another focused viewer is read too")
        await self.finish(gateway)
    }

    @Test func mainWindowReportsItsChatOnlyWhileVisible() async {
        let app = AppModel(defaults: self.scratch.defaults)
        let gateway = app.add(GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none), secret: nil)
        app.selectedGatewayId = gateway.id
        gateway.selectedKey = self.open
        app.mainChatVisible = false
        app.updateVisible()
        #expect(gateway.visibleChatKeys.isEmpty, "background or unfocused: nothing is visible")
        app.mainChatVisible = true
        #expect(gateway.visibleChatKeys == [self.open])
        gateway.selectedKey = self.other
        app.updateVisible()
        #expect(gateway.visibleChatKeys == [self.other], "follows the selection")
        app.mainChatVisible = false
        #expect(gateway.visibleChatKeys.isEmpty)
        app.remove(gateway.id)
        self.scratch.remove()
    }
}
