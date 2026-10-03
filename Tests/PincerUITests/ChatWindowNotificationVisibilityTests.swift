#if os(macOS)
import AppKit
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Native chat window notification visibility", .serialized)
struct NativeChatWindowNotificationVisibilityTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func fixture(_ body: (AppModel, GatewayStore, ChatWindowRef) throws -> Void) rethrows {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        let gateway = app.add(GatewayProfile(name: "Native window", url: "ws://127.0.0.1:1", authMode: .none), secret: nil)
        defer { app.remove(gateway.id); scratch.remove() }
        try body(app, gateway, ChatWindowRef(gatewayId: gateway.id, sessionKey: "agent:main:dashboard:trip"))
    }

    @Test func observerSamplesActualWindowPropertiesAndRealCloseEvent() {
        self.fixture { app, gateway, ref in
            let window = self.window()
            let observer = ChatWindowNotificationVisibility.ObserverView()
            observer.configure(app: app, ref: ref)
            window.contentView = observer
            defer { observer.detach(); window.close() }
            #expect(!window.isVisible)
            #expect(gateway.openWindowKeys == [ref.sessionKey], "attachment registers residency before its initial hidden sample")
            #expect(!app.notifier.windowVisible.contains(ref.target))

            window.orderFront(nil)
            observer.sampleVisibility()
            let actual = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            #expect(app.notifier.windowVisible.contains(ref.target) == actual,
                    "offscreen CI verifies actual sampled properties, not physical screen coverage")
            window.orderOut(nil)
            observer.sampleVisibility()
            #expect(!window.isVisible && !app.notifier.windowVisible.contains(ref.target))
            #expect(gateway.openWindowKeys.contains(ref.sessionKey), "ordering out does not destroy the resident owner")

            window.close() // AppKit posts its real willClose event; no fabricated notification.
            #expect(gateway.openWindowKeys.isEmpty && !app.notifier.windowVisible.contains(ref.target))
            observer.sampleVisibility()
            #expect(gateway.openWindowKeys.isEmpty, "a closed native window cannot re-register through a later sample")
        }
    }

    @Test func nativeReparentAndRefReconfigurationReleaseOnlyOldOwner() {
        self.fixture { app, gateway, firstRef in
            let first = self.window(), second = self.window()
            let observer = ChatWindowNotificationVisibility.ObserverView()
            observer.configure(app: app, ref: firstRef)
            first.contentView = observer
            defer { observer.detach(); first.close(); second.close() }
            #expect(gateway.openWindowKeys == [firstRef.sessionKey])
            let nextRef = ChatWindowRef(gatewayId: gateway.id, sessionKey: "agent:main:dashboard:garden")
            observer.configure(app: app, ref: nextRef)
            #expect(gateway.openWindowKeys == [nextRef.sessionKey])
            #expect(!app.notifier.windowVisible.contains(firstRef.target))
            second.contentView = observer
            #expect(gateway.openWindowKeys == [nextRef.sessionKey])
            first.close()
            #expect(gateway.openWindowKeys == [nextRef.sessionKey], "the old native window's real close must not release its rebound owner")
            second.close()
            #expect(gateway.openWindowKeys.isEmpty)
        }
    }
}
#endif
