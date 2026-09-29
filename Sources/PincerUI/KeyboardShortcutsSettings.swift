import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings → Shortcuts (#428): every Pincer command with its shortcut. Click a shortcut and type a
/// new one; Delete clears it, Esc cancels. Pincer's own clashes ask before moving the shortcut,
/// system shortcuts are refused and ones other apps commonly use get a warning.
struct KeyboardShortcutsSettingsSections: View {
    @State private var store = ShortcutStore.shared
    @State private var recording: ShortcutCommand?
    @State private var problem: (command: ShortcutCommand, message: String)?
    @State private var pending: PendingShortcut?
    #if os(macOS)
    @State private var quickCapture = QuickCaptureController.shared
    #endif

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.instructions)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Restore Defaults")) {
                    self.stopRecording()
                    self.problem = nil
                    self.store.resetAll()
                }
                .disabled(!self.store.hasCustomizations)
            }
            // Anchored to this first row, which is always there, rather than to one command's row.
            .alert(self.pending?.title ?? "", isPresented: Binding(get: { self.pending != nil }, set: { if !$0 { self.pending = nil } }),
                   presenting: self.pending) { pending in
                if pending.moves {
                    Button(L("Reassign")) { self.store.assign(pending.combo, to: pending.command) }
                    Button(L("Keep Both")) { self.store.set(pending.combo, for: pending.command) }
                } else {
                    Button(L("Use Anyway")) { self.store.set(pending.combo, for: pending.command) }
                }
                Button(L("Cancel"), role: .cancel) {}
            } message: { pending in
                Text(pending.message)
            }
            .onDisappear { self.stopRecording() }
            #if os(macOS)
            .background(MacShortcutCapture(isActive: self.recording != nil, onKey: self.handle, onClick: self.clickedAway))
            #endif
        }
        ForEach(ShortcutCommand.Category.allCases) { category in
            let commands = ShortcutCommand.listed(in: category)
            if !commands.isEmpty {
                Section {
                    ForEach(commands) { command in
                        self.row(command)
                    }
                } header: {
                    Text(category.title)
                }
            }
        }
        #if os(macOS)
        Section {
            LabeledContent(L("Quick Capture")) {
                Text(self.quickCapture.isEnabled ? self.quickCapture.shortcut.displayString : L("None"))
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("From Any App", bundle: .module)
        } footer: {
            Text("Change the Quick Capture shortcut in General.", bundle: .module)
        }
        #endif
    }

    private static var instructions: String {
        #if os(macOS)
        L("Click a shortcut, then press the new keys. Press Delete to remove it, or Esc to cancel.")
        #else
        L("Tap a shortcut, then press the new keys. Press Delete to remove it, or Esc to cancel.")
        #endif
    }

    private func row(_ command: ShortcutCommand) -> some View {
        let conflicted = self.store.conflicting.contains(command)
        return LabeledContent {
            HStack(spacing: Theme.Spacing.sm) {
                // Always laid out, so the recorder doesn't shift when a shortcut is changed or reset.
                let customized = self.store.isCustomized(command)
                Button {
                    self.problem = nil
                    self.store.reset(command)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("Reset to Default"))
                .accessibilityLabel(L("Reset \(command.title) to Default"))
                .opacity(customized ? 1 : 0)
                .disabled(!customized)
                .accessibilityHidden(!customized)
                ShortcutRecorderButton(
                    combo: self.store.combo(for: command), isRecording: self.recording == command,
                    title: command.title,
                    toggle: { self.toggleRecording(command) },
                    clear: { self.store.set(nil, for: command) },
                    reset: self.store.isCustomized(command) ? { self.store.reset(command) } : nil,
                    onKey: self.handle)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(command.title)
                    if conflicted {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(L("Another command uses this shortcut too."))
                            .accessibilityLabel(L("Another command uses this shortcut too."))
                    }
                }
                if let problem, problem.command == command {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// The click that opened or closed a recorder also reaches the click-away monitor first; this
    /// remembers what that click just stopped, so clicking the listening recorder turns it off.
    @State private var clickStopped: (command: ShortcutCommand, at: Date)?

    private func toggleRecording(_ command: ShortcutCommand) {
        if self.recording == command { return self.stopRecording() }
        if let stopped = self.clickStopped, stopped.command == command, Date().timeIntervalSince(stopped.at) < 1 {
            self.clickStopped = nil
            return
        }
        self.startRecording(command)
    }

    private func clickedAway() {
        guard let command = self.recording else { return }
        self.clickStopped = (command, Date())
        self.stopRecording()
    }

    private func startRecording(_ command: ShortcutCommand) {
        self.problem = nil
        self.recording = command
        self.store.isRecording = true
    }

    private func stopRecording() {
        self.recording = nil
        self.store.isRecording = false
    }

    /// A key typed while recording. Returns true when it was used.
    private func handle(_ input: ShortcutRecorderInput) -> Bool {
        guard let command = self.recording else { return false }
        switch input {
        case .cancel:
            self.stopRecording()
        case .clear:
            self.stopRecording()
            self.problem = nil
            self.store.set(nil, for: command)
        case let .combo(combo):
            #if os(macOS)
            let global = self.quickCapture.isEnabled ? self.quickCapture.shortcut.displayString : nil
            #else
            let global: String? = nil
            #endif
            switch self.store.validate(combo, for: command, globalHotKey: global) {
            case .ok:
                self.stopRecording()
                self.problem = nil
                self.store.set(combo, for: command)
            case let .blocked(message):
                // Keep listening so another combo can be tried right away.
                self.problem = (command, message)
            case let .warning(message):
                self.stopRecording()
                self.problem = nil
                self.pending = PendingShortcut(command: command, combo: combo, moves: false,
                                               title: L("Use \(combo.displayString) for “\(command.title)”?"), message: message)
            case let .conflict(others):
                self.stopRecording()
                self.problem = nil
                let names = ListFormatter.localizedString(byJoining: others.map { "“\($0.title)”" })
                self.pending = PendingShortcut(command: command, combo: combo, moves: true,
                                               title: L("\(combo.displayString) is already used"),
                                               message: L("\(names) uses \(combo.displayString). Reassign it to “\(command.title)”, leaving \(names) with no shortcut, or keep both?"))
            }
        }
        return true
    }
}

private struct PendingShortcut {
    let command: ShortcutCommand
    let combo: KeyCombo
    /// Takes the combo from the commands that have it.
    let moves: Bool
    let title: String
    let message: String
}

enum ShortcutRecorderInput {
    case cancel, clear
    case combo(KeyCombo)
}

/// The shortcut field: shows the combo, or "Type Shortcut" while listening.
private struct ShortcutRecorderButton: View {
    let combo: KeyCombo?
    let isRecording: Bool
    let title: String
    let toggle: () -> Void
    let clear: () -> Void
    let reset: (() -> Void)?
    let onKey: (ShortcutRecorderInput) -> Bool

    var body: some View {
        Button(action: self.toggle) {
            Text(self.label)
                .font(self.isRecording || self.combo == nil ? .body : .body.monospaced())
                .foregroundStyle(self.isRecording || self.combo == nil ? .secondary : .primary)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(self.isRecording ? .accentColor : nil)
        #if os(iOS)
        .background(PadShortcutCapture(isActive: self.isRecording, onKey: self.onKey))
        #endif
        .contextMenu {
            Button(L("Clear Shortcut"), action: self.clear).disabled(self.combo == nil)
            if let reset { Button(L("Reset to Default"), action: reset) }
        }
        .accessibilityLabel(L("\(self.title) shortcut"))
        .accessibilityValue(self.label)
        .accessibilityHint(L("Activate, then press the new keys."))
    }

    private var label: String {
        if self.isRecording { return L("Type Shortcut") }
        return self.combo?.displayString ?? L("None")
    }
}

#if os(macOS)
/// Listens for keys while a recorder is active. A local monitor sees keys before the menus do, so
/// the combo being recorded (even one Pincer already uses) doesn't run a command. Clicking
/// anywhere else in the window or switching apps stops recording.
private struct MacShortcutCapture: NSViewRepresentable {
    let isActive: Bool
    let onKey: (ShortcutRecorderInput) -> Bool
    let onClick: () -> Void

    @MainActor
    final class Coordinator {
        var monitor: Any?
        var onKey: ((ShortcutRecorderInput) -> Bool)?
        var onClick: (() -> Void)?
        var resign: NSObjectProtocol?

        func start() {
            guard self.monitor == nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let onKey = self.onKey else { return event }
                // Any click stops recording, like the Quick Capture recorder; the click still lands.
                guard event.type == .keyDown else {
                    self.onClick?()
                    return event
                }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if modifiers.isEmpty {
                    switch event.keyCode {
                    case 53: return onKey(.cancel) ? nil : event
                    case 51, 117: return onKey(.clear) ? nil : event
                    default: break
                    }
                }
                guard let combo = KeyCombo(macKeyCode: event.keyCode,
                                           unmodifiedCharacters: event.characters(byApplyingModifiers: []),
                                           eventModifierFlags: modifiers.rawValue) else { return event }
                return onKey(.combo(combo)) ? nil : event
            }
            self.resign = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.onKey?(.cancel) }
            }
        }

        /// Also resumes Pincer's shortcuts, so closing Settings mid-recording can't leave them off.
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resign { NotificationCenter.default.removeObserver(resign) }
            if self.monitor != nil { ShortcutStore.shared.isRecording = false }
            self.monitor = nil
            self.resign = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = self.onKey
        context.coordinator.onClick = self.onClick
        if self.isActive { context.coordinator.start() } else { context.coordinator.stop() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }
}
#else
/// iPad with a hardware keyboard: a hidden first responder catches the presses while recording.
private struct PadShortcutCapture: UIViewRepresentable {
    let isActive: Bool
    let onKey: (ShortcutRecorderInput) -> Bool

    final class CaptureView: UIView {
        var onKey: ((ShortcutRecorderInput) -> Bool)?
        var wantsCapture = false
        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if self.window == nil, self.isFirstResponder {
                self.resignFirstResponder()
                ShortcutStore.shared.isRecording = false
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let key = presses.first?.key, let onKey else { return super.pressesBegan(presses, with: event) }
            var modifiers: KeyCombo.Modifiers = []
            if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
            if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            let usage = key.keyCode.rawValue
            if modifiers.isEmpty, usage == UIKeyboardHIDUsage.keyboardEscape.rawValue {
                _ = onKey(.cancel)
            } else if modifiers.isEmpty, usage == UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue
                || usage == UIKeyboardHIDUsage.keyboardDeleteForward.rawValue {
                _ = onKey(.clear)
            } else if let combo = KeyCombo(hidUsage: usage, modifiers: modifiers) {
                _ = onKey(.combo(combo))
            }
        }
    }

    func makeUIView(context: Context) -> CaptureView { CaptureView() }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.onKey = self.onKey
        view.wantsCapture = self.isActive
        guard self.isActive != view.isFirstResponder else { return }
        DispatchQueue.main.async {
            // Reads the latest wish, in case a later update flipped it meanwhile.
            if view.wantsCapture, !view.isFirstResponder, view.window != nil { view.becomeFirstResponder() }
            if !view.wantsCapture, view.isFirstResponder { view.resignFirstResponder() }
        }
    }
}

/// iPad: Settings → Keyboard Shortcuts, pushed from the Settings sheet.
struct KeyboardShortcutsSettingsPage: View {
    var body: some View {
        Form { KeyboardShortcutsSettingsSections() }
            .formStyle(.grouped)
            .navigationTitle(L("Keyboard Shortcuts"))
    }
}
#endif
