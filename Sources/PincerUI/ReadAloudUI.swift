import PincerKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the Read Aloud menu command and the auto-read hook act on for the chat in the focused window.
@MainActor
@Observable
final class ReadAloudChatState {
    weak var chat: ChatStore?
    weak var gateway: GatewayStore?
    /// The window is frontmost and this chat is the one on screen; auto-read only speaks then.
    var isVisible = true

    var lastReply: (id: String, text: String)? {
        guard let chat else { return nil }
        for item in chat.items.reversed() {
            if let text = SpeechText.speakableText(for: item) { return (item.transcriptId ?? item.id, text) }
        }
        return nil
    }

    /// Reads the newest reply, or stops if something is being read.
    func toggleLastReply() {
        let controller = ReadAloudController.shared
        if controller.isActive { controller.stop(); return }
        guard let reply = self.lastReply else { return }
        controller.start(messageId: reply.id, text: reply.text, gateway: self.gateway?.voice)
    }

    var isEnabled: Bool { ReadAloudController.shared.isActive || self.lastReply != nil }
}

extension FocusedValues {
    @Entry var readAloud: ReadAloudChatState?
}

enum ReadAloudSupport {
    @MainActor static var isVoiceOverRunning: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning
        #else
        NSWorkspace.shared.isVoiceOverEnabled
        #endif
    }
}

#if os(macOS)
/// Edit ▸ Read Last Reply Aloud (⌥⌘L) for the focused chat; "Stop Reading Aloud" while it reads.
struct ReadAloudCommands: Commands {
    @FocusedValue(\.readAloud) private var readAloud

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            ReadAloudCommandButton(state: self.readAloud)
        }
    }
}

private struct ReadAloudCommandButton: View {
    let state: ReadAloudChatState?

    var body: some View {
        let speaking = ReadAloudController.shared.isActive
        Button(speaking ? L("Stop Reading Aloud") : L("Read Last Reply Aloud")) { self.state?.toggleLastReply() }
            .shortcut(.readAloud)
            .disabled(self.state?.isEnabled != true)
    }
}
#endif

/// The "Speaking… / Stop" capsule over the bottom of the transcript while Read Aloud runs.
struct ReadAloudPill: View {
    let controller: ReadAloudController

    var body: some View {
        if case let phase = self.controller.phase, phase != .idle {
            Button { self.controller.stop() } label: {
                HStack(spacing: 8) {
                    if case .preparing = phase {
                        ProgressView().controlSize(.small)
                        Text("Preparing…", bundle: .module)
                    } else {
                        Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative)
                        Text("Speaking…", bundle: .module)
                    }
                    Text("·").foregroundStyle(.secondary)
                    Text("Stop", bundle: .module).fontWeight(.semibold)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Stop Reading Aloud"))
            .accessibilityValue(phase == .idle ? "" : { if case .preparing = phase { L("Preparing") } else { L("Speaking") } }())
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ReadAloudPillHeight.self, value: geometry.size.height)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ReadAloudPillHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum ReadAloudPillLayout {
    static let bottomSpacing: CGFloat = 8
}

/// Wires a chat into Read Aloud: the menu command, the pill and auto-read of new replies.
struct ReadAloudModifier: ViewModifier {
    let chat: ChatStore
    let gateway: GatewayStore
    let bottomInset: CGFloat
    let controller: ReadAloudController
    @Binding var pillInset: CGFloat
    @State private var state = ReadAloudChatState()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @AppStorage(ReadAloudSettings.autoReadKey) private var autoRead = false

    func body(content: Content) -> some View {
        let pillInset = self.$pillInset
        content
            // In the split view only the focused side answers the menu command and shows the pill (#404).
            .focusedSceneValue(\.readAloud, self.paneIsActive ? self.state : nil)
            .overlay(alignment: .bottom) {
                if self.paneIsActive { ReadAloudPill(controller: self.controller)
                    .padding(.bottom, self.bottomInset + ReadAloudPillLayout.bottomSpacing)
                    .animation(.snappy, value: self.controller.phase) }
            }
            .onPreferenceChange(ReadAloudPillHeight.self) { height in
                let inset = height > 0 ? height + ReadAloudPillLayout.bottomSpacing : 0
                if abs(pillInset.wrappedValue - inset) > 0.5 { pillInset.wrappedValue = inset }
            }
            .onChange(of: self.paneIsActive) { _, isActive in
                if !isActive { pillInset.wrappedValue = 0 }
            }
            .background { self.hardwareShortcut }
            // Lowest priority: the composer, find bar and menus see Esc first and only pass it on when they don't use it.
            .onKeyPress(.escape) { self.stopWithEscape() }
            .onAppear { self.install() }
            .onChange(of: self.scenePhase) {
                self.state.isVisible = self.scenePhase == .active
                // Another window showing this chat may have closed and taken the handler with it.
                if self.state.isVisible { self.install() }
            }
            .onChange(of: self.autoRead) { self.install() }
            .onDisappear { self.uninstall() }
    }

    /// ⌥⌘L on iPad hardware keyboards (macOS has the Edit menu command); only the active pane answers.
    @ViewBuilder private var hardwareShortcut: some View {
        #if os(iOS)
        if self.paneIsActive {
            Button(self.controller.isActive ? L("Stop Reading Aloud") : L("Read Last Reply Aloud")) {
                if self.controller.isActive { self.controller.stop() }
                else { self.state.toggleLastReply() }
            }
            .shortcut(.readAloud)
            .disabled(!self.state.isEnabled)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        #endif
    }

    private func stopWithEscape() -> KeyPress.Result {
        let controller = self.controller
        guard self.paneIsActive, controller.isActive, !controller.isDictating else { return .ignored }
        controller.stop()
        return .handled
    }

    private func install() {
        self.state.chat = self.chat
        self.state.gateway = self.gateway
        self.state.isVisible = self.scenePhase == .active
        guard self.autoRead else { return self.uninstall() }
        let state = self.state
        let controller = self.controller
        self.chat.onFinalAssistantReplyOwner = state
        self.chat.onFinalAssistantReply = { [weak state, weak controller] item in
            guard let state, let controller, state.isVisible, !ReadAloudSupport.isVoiceOverRunning, !controller.isDictating,
                  let text = SpeechText.speakableText(for: item) else { return }
            controller.start(messageId: item.transcriptId ?? item.id, text: text, gateway: state.gateway?.voice)
        }
    }

    private func uninstall() {
        guard self.chat.onFinalAssistantReplyOwner === self.state || self.chat.onFinalAssistantReplyOwner == nil else { return }
        self.chat.onFinalAssistantReply = nil
        self.chat.onFinalAssistantReplyOwner = nil
    }
}

extension View {
    /// Read Aloud for a chat: the Edit menu command, the Stop pill and auto-read.
    func readAloud(chat: ChatStore, gateway: GatewayStore, bottomInset: CGFloat, pillInset: Binding<CGFloat>,
                   controller: ReadAloudController = .shared) -> some View
    {
        self.modifier(ReadAloudModifier(chat: chat, gateway: gateway, bottomInset: bottomInset,
                                        controller: controller, pillInset: pillInset))
    }
}
