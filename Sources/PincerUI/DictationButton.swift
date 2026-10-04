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
    private let injectedModel: DictationModel?
    init(model: DictationModel? = nil) { self.injectedModel = model }
    lazy var model = self.injectedModel ?? DictationModel(engine: SpeechDictationEngine())
}

/// The composer's microphone button: dictates into the draft, live, and never sends.
struct DictationButton: View {
    let model: DictationModel
    let app: AppModel
    let gatewayID: UUID
    let sessionKey: String
    @Binding var draft: String
    /// The field's selection in UTF-16 units; nil until it reports one.
    let selection: NSRange?
    /// Called with the UTF-16 offset just after the dictated text, every time the transcript changes.
    let onCaret: (Int) -> Void
    /// Whether the text field has keyboard focus; when it doesn't, dictation goes at the end of the draft.
    let isFieldFocused: Bool
    let onRequestFocus: () -> Void
    @Environment(\.dictationSceneID) private var sceneID
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 14

    private var target: DictationTarget? {
        self.sceneID.map { DictationTarget(sceneID: $0, gatewayID: self.gatewayID, sessionKey: self.sessionKey) }
    }

    var body: some View {
        Group {
            if self.model.isAvailable || self.model.isActive {
                self.micButton(listening: self.model.isActive)
            }
        }
        .onChange(of: self.app.dictationToggleRequest) { _, request in
            guard let target = self.target,
                  request?.matches(target: target, paneIsActive: self.paneIsActive) == true,
                  self.model.isAvailable || self.model.isActive else { return }
            self.toggle(focusing: true)
        }
        .onChange(of: self.model.isActive, initial: true) { self.publishState() }
        .onDisappear { self.removePublishedState(for: self.target) }
        .onChange(of: self.target) { old, _ in
            self.removePublishedState(for: old)
            self.publishState()
        }
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

    private func micButton(listening: Bool) -> some View {
        let button = Button(action: { self.toggle() }) {
            DictationMicLabel(listening: listening, pulsing: self.model.isListening, iconSize: min(self.iconSize, 22))
        }
        return self.focusedPaneShortcut(button)
            .buttonStyle(.plain)
            .frame(width: 32, height: Composer.controlHeight)
            .help(self.helpText(listening: listening))
            .accessibilityLabel(listening ? L("Stop Dictation") : L("Dictate Message"))
    }

    private func helpText(listening: Bool) -> String {
        guard !listening else { return L("Stop Dictation") }
        let base = L("Dictate a message with your voice")
        // In split view only the focused pane's button has the shortcut.
        guard self.paneIsActive else { return base }
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

    /// Tells this window's palette whether this composer is dictating and available.
    private func publishState() {
        guard let target = self.target else { return }
        if self.model.isActive {
            self.app.dictationActiveTargets.insert(target)
        } else {
            self.app.dictationActiveTargets.remove(target)
        }
        if self.paneIsActive && self.model.isAvailable {
            self.app.dictationAvailableTargets.insert(target)
        } else {
            self.app.dictationAvailableTargets.remove(target)
        }
    }

    private func removePublishedState(for target: DictationTarget?) {
        guard let target else { return }
        self.app.dictationActiveTargets.remove(target)
        self.app.dictationAvailableTargets.remove(target)
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

/// The mic glyph, with a text title so the iPad ⌘-hold shortcut overlay can name it.
private struct DictationMicLabel: View {
    let listening: Bool
    let pulsing: Bool
    let iconSize: CGFloat

    var body: some View {
        let title = self.listening ? L("Stop Dictation") : L("Dictate Message")
        let style: AnyShapeStyle = self.listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
        Label {
            Text(title)
        } icon: {
            Image(systemName: self.listening ? "mic.fill" : "mic")
        }
        .labelStyle(.iconOnly)
        .font(.system(size: self.iconSize, weight: .semibold))
        .foregroundStyle(style)
        .symbolEffect(.pulse, isActive: self.pulsing)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }
}

extension View {
    /// Ends dictation (keeping the text) when the field is edited by hand, the chat changes or the composer goes away.
    func dictationLifecycle(_ model: DictationModel, draft: String, chatKey: String) -> some View {
        self
            .onChange(of: draft) { _, text in model.draftChangedExternally(text) }
            .onChange(of: chatKey) { model.invalidateDeferredSend(); model.finish() }
            .onDisappear { model.invalidateDeferredSend(); model.finish() }
    }
}
