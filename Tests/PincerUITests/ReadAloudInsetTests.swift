#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class HeldInsetSpeaker: ReadAloudLocalSpeaking {
    private var completion: CheckedContinuation<Bool, Never>?

    func speak(_: String, voice: String?, rate: Float) async -> Bool {
        await withCheckedContinuation { self.completion = $0 }
    }

    func stop() {
        self.completion?.resume(returning: false)
        self.completion = nil
    }
}

@MainActor
private final class SilentInsetPlayer: ReadAloudClipPlaying {
    func play(_: TTSClip) async -> Bool { false }
    func stop() {}
}

@MainActor
private final class InsetValue {
    var value: CGFloat = 0
}

@MainActor
@Observable
private final class PaneActivity {
    var isActive: Bool

    init(isActive: Bool) { self.isActive = isActive }
}

@MainActor
private struct ReadAloudInsetHost: View {
    let chat: ChatStore
    let gateway: GatewayStore
    let controller: ReadAloudController
    let inset: Binding<CGFloat>
    let pane: PaneActivity

    var body: some View {
        Color.clear
            .frame(width: 420, height: 760)
            .readAloud(chat: self.chat, gateway: self.gateway, bottomInset: 56, pillInset: self.inset,
                       controller: self.controller)
            .environment(\.chatPaneIsActive, self.pane.isActive)
            .environment(\.scenePhase, .active)
    }
}

@MainActor
@Suite("Read Aloud transcript inset", .serialized)
struct ReadAloudInsetTests {
    private static var keepAlive: [NSHostingView<ReadAloudInsetHost>] = []
    private static var transcriptLists: [(NSWindow, TranscriptList.Coordinator)] = []

    private func host(active: Bool, controller: ReadAloudController, defaults: UserDefaults, value: InsetValue)
        -> (NSHostingView<ReadAloudInsetHost>, PaneActivity, TranscriptContext)
    {
        let profile = GatewayProfile(name: "Read Aloud inset", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
        let chat = gateway.chat(for: "agent:main:inset")
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "main", name: "Claw"), sessionKey: chat.sessionKey,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let pane = PaneActivity(isActive: active)
        let root = ReadAloudInsetHost(chat: chat, gateway: gateway, controller: controller,
                                      inset: Binding(get: { value.value }, set: { value.value = $0 }), pane: pane)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 760)
        host.layout()
        Self.keepAlive.append(host)
        return (host, pane, context)
    }

    @Test func activePillReservesItsMeasuredHeightAndGapThenClears() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set(ReadAloudSettings.sourceDevice, forKey: ReadAloudSettings.sourceKey)
        let speaker = HeldInsetSpeaker()
        let controller = ReadAloudController(clipPlayer: SilentInsetPlayer(), localSpeaker: speaker, defaults: scratch.defaults)
        let value = InsetValue()
        let (host, _, context) = self.host(active: true, controller: controller, defaults: scratch.defaults, value: value)

        controller.start(messageId: "inset-reply", text: "A reply being read aloud.", gateway: nil)
        #expect(await eventually(timeout: .seconds(10)) { controller.phase == .speaking("inset-reply") && value.value > 0 })
        host.layout()

        let pill = NSHostingView(rootView: ReadAloudPill(controller: controller).fixedSize())
        pill.layout()
        #expect(value.value > pill.fittingSize.height, "the reserve includes space below the visible pill")
        #expect(abs(value.value - pill.fittingSize.height - 8) < 1, "the reserve matches the measured pill plus its 8pt gap")

        let transcriptCoordinator = TranscriptList.Coordinator(context: context)
        let transcriptScroll = transcriptCoordinator.makeScrollView()
        let transcriptWindow = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 760),
                                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        transcriptWindow.contentView = transcriptScroll
        transcriptScroll.frame = transcriptWindow.contentView?.bounds ?? .zero
        transcriptWindow.orderBack(nil)
        transcriptCoordinator.update(rows: [], context: context, insets: (0, value.value))
        #expect(abs(transcriptScroll.contentInsets.bottom - TranscriptLayout.verticalInset - value.value) < 0.5,
                "the measured pill reserve reaches the native transcript bottom inset")
        Self.transcriptLists.append((transcriptWindow, transcriptCoordinator))

        controller.stop()
        #expect(await eventually(timeout: .seconds(10)) { controller.phase == .idle && value.value == 0 })
        host.layout()
    }

    @Test func inactivePaneDoesNotReserveSpaceForThePill() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set(ReadAloudSettings.sourceDevice, forKey: ReadAloudSettings.sourceKey)
        let speaker = HeldInsetSpeaker()
        let controller = ReadAloudController(clipPlayer: SilentInsetPlayer(), localSpeaker: speaker, defaults: scratch.defaults)
        let activeValue = InsetValue()
        let inactiveValue = InsetValue()
        let (activeHost, pane, _) = self.host(active: true, controller: controller, defaults: scratch.defaults, value: activeValue)
        _ = self.host(active: false, controller: controller, defaults: scratch.defaults, value: inactiveValue)
        controller.start(messageId: "other-pane", text: "Another pane is speaking.", gateway: nil)

        #expect(await eventually(timeout: .seconds(10)) {
            controller.phase == .speaking("other-pane") && activeValue.value > 0
        })
        #expect(inactiveValue.value == 0, "only the active pane reserves room for the shared pill")
        pane.isActive = false
        activeHost.layout()
        #expect(await eventually(timeout: .seconds(10)) { activeValue.value == 0 }, "leaving the pane clears its previous reserve")
        pane.isActive = true
        activeHost.layout()
        #expect(await eventually(timeout: .seconds(10)) { activeValue.value > 0 }, "returning to the pane restores its reserve while speaking continues")
        controller.stop()
        #expect(await eventually(timeout: .seconds(10)) { activeValue.value == 0 })
        #expect(inactiveValue.value == 0)
    }
}
#endif
