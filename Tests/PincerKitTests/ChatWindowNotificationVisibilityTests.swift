import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Chat window notification visibility")
struct ChatWindowNotificationVisibilityTests {
    @Test func hiddenOwnedWindowStopsSuppressingWithoutReleasingItsChat() {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        let gateway = app.add(GatewayProfile(name: "Window visibility", url: "ws://127.0.0.1:1", authMode: .none), secret: nil)
        let main = "agent:main:main"
        let hidden = "agent:main:dashboard:trip"
        let ref = ChatWindowRef(gatewayId: gateway.id, sessionKey: hidden)
        let owner = UUID()
        let target = Notifier.Target(gatewayId: gateway.id, sessionKey: hidden)
        defer {
            app.chatWindowClosed(ref, windowID: owner)
            app.remove(gateway.id)
            scratch.remove()
        }
        gateway.selectedKey = main
        app.selectedGatewayId = gateway.id
        app.updateVisible()
        let mainTarget = Notifier.Target(gatewayId: gateway.id, sessionKey: main)
        #expect(app.notifier.isShowing(mainTarget))
        #expect(!app.notifier.isShowing(target))

        app.chatWindowOpened(ref, windowID: owner)
        app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
        #expect(app.notifier.isShowing(target), "a visible detached window suppresses its own target")
        app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: false)
        #expect(!app.notifier.isShowing(target), "an open but hidden window must allow notifications")
        #expect(app.notifier.isShowing(mainTarget), "hiding another window preserves main selection visibility")
        #expect(gateway.openWindowKeys.contains(hidden) && gateway.isChatPinned(hidden), "hidden windows retain residency independently of notification visibility")
    }
}
