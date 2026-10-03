import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Chat window notification visibility")
struct ChatWindowNotificationVisibilityTests {
    private func withApp(_ body: (AppModel, GatewayStore, ChatWindowRef) -> Void) {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        let gateway = app.add(GatewayProfile(name: "Owned windows", url: "ws://127.0.0.1:1", authMode: .none), secret: nil)
        defer { app.remove(gateway.id); scratch.remove() }
        body(app, gateway, ChatWindowRef(gatewayId: gateway.id, sessionKey: "agent:main:dashboard:trip"))
    }

    @Test func twoOwnersAggregateVisibilityWithoutSharingLifetime() {
        self.withApp { app, gateway, ref in
            let first = UUID(), second = UUID()
            app.chatWindowOpened(ref, windowID: first)
            app.chatWindowOpened(ref, windowID: second)
            #expect(!app.notifier.windowVisible.contains(ref.target), "owned windows begin unobserved, not visibly assumed")
            app.chatWindowVisibilityChanged(ref, windowID: first, isVisible: true)
            app.chatWindowVisibilityChanged(ref, windowID: second, isVisible: true)
            app.chatWindowVisibilityChanged(ref, windowID: first, isVisible: false)
            #expect(app.notifier.windowVisible.contains(ref.target))
            app.chatWindowClosed(ref, windowID: first)
            #expect(app.notifier.windowVisible.contains(ref.target) && gateway.openWindowKeys.contains(ref.sessionKey))
            app.chatWindowVisibilityChanged(ref, windowID: second, isVisible: false)
            #expect(!app.notifier.windowVisible.contains(ref.target) && gateway.isChatPinned(ref.sessionKey))
            app.chatWindowClosed(ref, windowID: second)
            #expect(!gateway.openWindowKeys.contains(ref.sessionKey))
        }
    }

    @Test func duplicateOpenAndCloseAreIdempotent() {
        self.withApp { app, gateway, ref in
            let owner = UUID()
            app.chatWindowOpened(ref, windowID: owner)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            app.chatWindowOpened(ref, windowID: owner)
            #expect(app.windowRefCounts[ref] == 1 && app.notifier.windowVisible.contains(ref.target))
            app.chatWindowClosed(ref, windowID: owner)
            app.chatWindowClosed(ref, windowID: owner)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            #expect(app.windowRefCounts[ref] == nil && gateway.openWindowKeys.isEmpty)
            #expect(!app.notifier.windowVisible.contains(ref.target), "closed owners cannot resurrect visibility")
        }
    }

    @Test func rebindRejectsStaleVisibilityAndClose() {
        self.withApp { app, gateway, old in
            let owner = UUID()
            let current = ChatWindowRef(gatewayId: gateway.id, sessionKey: "agent:main:dashboard:garden")
            app.chatWindowOpened(old, windowID: owner)
            app.chatWindowVisibilityChanged(old, windowID: owner, isVisible: true)
            app.chatWindowOpened(current, windowID: owner)
            #expect(gateway.openWindowKeys == [current.sessionKey])
            #expect(!app.notifier.windowVisible.contains(old.target))
            app.chatWindowVisibilityChanged(current, windowID: owner, isVisible: true)
            app.chatWindowVisibilityChanged(old, windowID: owner, isVisible: false)
            app.chatWindowClosed(old, windowID: owner)
            #expect(app.notifier.windowVisible.contains(current.target) && gateway.openWindowKeys == [current.sessionKey])
            app.chatWindowClosed(current, windowID: owner)
            #expect(gateway.openWindowKeys.isEmpty)
        }
    }

    @Test func legacyAndOwnedClosingsDoNotStealEachOthersVisibility() {
        self.withApp { app, gateway, ref in
            let owner = UUID()
            app.chatWindowOpened(ref)
            app.chatWindowOpened(ref, windowID: owner)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: false)
            #expect(app.notifier.windowVisible.contains(ref.target), "legacy visible residency remains compatible")
            app.chatWindowClosed(ref, windowID: owner)
            #expect(app.notifier.windowVisible.contains(ref.target) && gateway.openWindowKeys.contains(ref.sessionKey))
            app.chatWindowOpened(ref, windowID: owner)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            app.chatWindowClosed(ref)
            app.chatWindowClosed(ref)
            #expect(app.notifier.windowVisible.contains(ref.target) && app.windowRefCounts[ref] == 1)
            app.chatWindowClosed(ref, windowID: owner)
            #expect(!app.notifier.windowVisible.contains(ref.target) && gateway.openWindowKeys.isEmpty)
        }
    }

    @Test func deletedAndUnknownGatewaysCannotRetainOwners() {
        self.withApp { app, gateway, ref in
            let owner = UUID()
            app.chatWindowOpened(ref, windowID: owner)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            app.remove(gateway.id)
            #expect(app.windowRefCounts[ref] == nil && !app.notifier.windowVisible.contains(ref.target))
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            app.chatWindowOpened(ref, windowID: owner)
            app.chatWindowClosed(ref, windowID: owner)
            #expect(app.windowRefCounts[ref] == nil && !app.notifier.windowVisible.contains(ref.target))
        }
    }

    @Test func onlyVisibilityTransitionsClearTheOwnedTargetsNotifications() {
        self.withApp { app, _, ref in
            let owner = UUID()
            var targetClears = 0
            let previous = app.notifier.clearTargetProbe
            app.notifier.clearTargetProbe = { target in
                previous?(target)
                if target == ref.target { targetClears += 1 }
            }
            defer { app.notifier.clearTargetProbe = previous }
            app.chatWindowOpened(ref, windowID: owner)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: false)
            #expect(targetClears == 0, "initial hidden residency must not erase an unseen notification")
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            #expect(targetClears == 1, "the first visible transition reaches actual target clear")
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            app.chatWindowOpened(ref, windowID: owner)
            #expect(targetClears == 1, "duplicate reports do not repeat clearing")
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: false)
            #expect(targetClears == 1)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
            #expect(targetClears == 2, "showing the target again clears its newly arrived notifications")
            app.chatWindowClosed(ref, windowID: owner)
        }
    }

    @Test func detachedHiddenStateDoesNotChangeMainSplitReadViewersOrFocus() {
        self.withApp { app, gateway, ref in
            let main = "agent:main:main", split = "agent:main:dashboard:garden"
            gateway.selectedKey = main
            gateway.openInSplit(split)
            gateway.splitPaneFocused = true
            gateway.setVisibleChat(main, viewer: GatewayStore.mainViewer)
            gateway.setVisibleChat(split, viewer: "split-test")
            let owner = UUID()
            app.chatWindowOpened(ref, windowID: owner)
            app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: false)
            #expect(gateway.visibleChatKeys == [main, split], "notification visibility does not change focused read-viewer accounting")
            #expect(gateway.focusedKey == split && gateway.visibleSplitKey == split && gateway.selectedKey == main)
            app.chatWindowClosed(ref, windowID: owner)
        }
    }

    @Test func ownerCanRebindAcrossGatewaysAndSelectionChangesDoNotStealIt() {
        self.withApp { app, first, old in
            let second = app.add(GatewayProfile(name: "Other window gateway", url: "ws://127.0.0.1:2", authMode: .none), secret: nil)
            defer { app.remove(second.id) }
            let owner = UUID()
            let current = ChatWindowRef(gatewayId: second.id, sessionKey: old.sessionKey)
            app.chatWindowOpened(old, windowID: owner)
            app.chatWindowVisibilityChanged(old, windowID: owner, isVisible: true)
            app.selectedGatewayId = second.id
            #expect(first.openWindowKeys.contains(old.sessionKey) && app.notifier.windowVisible.contains(old.target))
            app.chatWindowOpened(current, windowID: owner)
            app.chatWindowVisibilityChanged(current, windowID: owner, isVisible: true)
            app.chatWindowClosed(old, windowID: owner)
            #expect(first.openWindowKeys.isEmpty && second.openWindowKeys == [current.sessionKey])
            #expect(!app.notifier.windowVisible.contains(old.target) && app.notifier.windowVisible.contains(current.target),
                    "same session string on another Gateway has a distinct notification identity")
            app.remove(first.id)
            #expect(second.openWindowKeys.contains(current.sessionKey) && app.notifier.windowVisible.contains(current.target))
            app.chatWindowClosed(current, windowID: owner)
        }
    }

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
