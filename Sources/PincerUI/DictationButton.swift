import PincerKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Builds the engine and model once, when first needed; `@State`'s own initial value is rebuilt on every view init.
@MainActor
final class DictationHolder {
    lazy var model = DictationModel(engine: SpeechDictationEngine())
}

/// The composer's microphone button: dictates into the draft, live, and never sends.
struct DictationButton: View {
    let model: DictationModel
    let app: AppModel
    let sessionKey: String
    @Binding var draft: String
    /// The field's selection in UTF-16 units; nil until it reports one.
    let selection: NSRange?
    /// Called with the UTF-16 offset just after the dictated text, every time the transcript changes.
    let onCaret: (Int) -> Void
    /// Whether the text field has keyboard focus; when it doesn't, dictation goes at the end of the draft.
    let isFieldFocused: Bool
    let onRequestFocus: () -> Void
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 14

    var body: some View {
        Group {
            if self.model.isAvailable || self.model.isActive {
                let listening = self.model.isActive
                self.focusedPaneShortcut(Button(action: { self.toggle() }) {
                    Label {
                        Text(listening ? L("Stop Dictation") : L("Dictate Message"))
                    } icon: {
                        Image(systemName: listening ? "mic.fill" : "mic")
                    }
                    .labelStyle(.iconOnly)
                        .font(.system(size: min(self.iconSize, 22), weight: .semibold))
                        .foregroundStyle(listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .symbolEffect(.pulse, isActive: self.model.isListening)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                })
                .buttonStyle(.plain)
                .frame(width: 32, height: Composer.controlHeight)
                .help(self.helpText(listening: listening))
                .accessibilityLabel(listening ? L("Stop Dictation") : L("Dictate Message"))
            }
        }
        .onChange(of: self.app.dictationToggleRequest) { _, request in
            guard request?.sessionKey == self.sessionKey, self.model.isAvailable || self.model.isActive else { return }
            self.toggle(focusing: true)
        }
        .onChange(of: self.model.isActive, initial: true) { self.publishState() }
        .onDisappear { self.app.dictationActiveKeys.remove(self.sessionKey) }
        .onChange(of: self.sessionKey) { old, _ in self.app.dictationActiveKeys.remove(old) }
        .onChange(of: self.model.isAvailable) { self.publishState() }
        .onChange(of: self.paneIsActive) { self.publishState() }
        // Outside the availability check, so "isn't available" can still be shown.
        .onChange(of: self.model.phase) { old, phase in
            if phase == .idle, old == .listening || old == .finishing, !self.model.endedForSend {
                AccessibilityNotification.Announcement(L("Dictation stopped")).post()
            }
        }
        .alert(self.alertTitle, isPresented: Binding(
            get: { self.model.issue != nil }, set: { if !$0 { self.model.issue = nil } }))
        {
            if let issue = self.model.issue, issue.canOpenSettings {
                Button(L("Open Settings")) { Self.openSettings(issue) }
            }
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(self.model.issue?.message ?? "")
        }
    }

    private func helpText(listening: Bool) -> String {
        guard !listening else { return L("Stop Dictation") }
        let base = L("Dictate a message with your voice")
        return ShortcutCommand.toggleDictation.displayShortcut.map { "\(base) (\($0))" } ?? base
    }

    /// From the shortcut or palette, a field without focus gets it, and dictation starts at the end of the draft.
    private func toggle(focusing: Bool = false) {
        let selection = self.isFieldFocused ? self.selection : nil
        if focusing, !self.model.isActive, !self.isFieldFocused { self.onRequestFocus() }
        self.model.toggle(draft: self.draft, selection: selection) { text, caret in
            self.draft = text
            self.onCaret(caret)
        }
    }

    /// Tells the palette whether this chat is dictating and whether dictation is available.
    private func publishState() {
        if self.model.isActive {
            self.app.dictationActiveKeys.insert(self.sessionKey)
        } else {
            self.app.dictationActiveKeys.remove(self.sessionKey)
        }
        if self.paneIsActive { self.app.dictationAvailable = self.model.isAvailable }
    }

    @ViewBuilder private func focusedPaneShortcut(_ button: some View) -> some View {
        if self.paneIsActive {
            button.shortcut(.toggleDictation)
        } else {
            button
        }
    }

    private var alertTitle: String {
        switch self.model.issue {
        case .failed: L("Dictation Stopped")
        case .speechDenied, .micDenied, .speechRestricted: L("Dictation Is Off")
        default: L("Dictation Isn't Available")
        }
    }

    private static func openSettings(_ issue: DictationIssue) {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        let pane = issue == .micDenied ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
        #endif
    }
}

extension View {
    /// Ends dictation (keeping the text) when the field is edited by hand, the chat changes or the composer goes away.
    func dictationLifecycle(_ model: DictationModel, draft: String, chatKey: String) -> some View {
        self
            .onChange(of: draft) { _, text in model.draftChangedExternally(text) }
            .onChange(of: chatKey) { model.finish() }
            .onDisappear { model.finish() }
    }
}
