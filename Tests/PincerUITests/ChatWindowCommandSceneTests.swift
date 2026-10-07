#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor private final class SceneCapture { var target: ChatWindowCommandTarget? }
private struct CommandSceneProbe: View {
    @Environment(\.isDetachedChatScene) private var detached
    @Environment(\.chatWindowKey) private var key
    let capture: SceneCapture
    let gatewayID: UUID
    var body: some View {
        Text("Scene context").onAppear {
            self.capture.target = .init(ref: .init(gatewayId: self.gatewayID, sessionKey: self.key ?? "main"), isDetached: self.detached)
        }
    }
}
@MainActor @Suite(.timeLimit(.minutes(2))) struct ChatWindowCommandSceneTests {
    @Test func splitKeyOverrideDoesNotMarkDetachedButActualSceneModifierDoes() async throws {
        _ = NSApplication.shared
        let main = SceneCapture(), detached = SceneCapture(), id = UUID()
        let host = NSHostingView(rootView: VStack {
            CommandSceneProbe(capture: main, gatewayID: id).environment(\.chatWindowKey, "split")
            CommandSceneProbe(capture: detached, gatewayID: id).environment(\.chatWindowKey, "front").modifier(DetachedChatScene())
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try #require(await eventually { host.layoutSubtreeIfNeeded(); return main.target != nil && detached.target != nil })
        #expect(main.target == ChatWindowCommandTarget(ref: .init(gatewayId: id, sessionKey: "split"), isDetached: false))
        #expect(detached.target == ChatWindowCommandTarget(ref: .init(gatewayId: id, sessionKey: "front"), isDetached: true))
    }
}
#endif
