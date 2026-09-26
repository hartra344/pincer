#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// Settings → General → Quick Capture: turn the global shortcut on or off, record a new one, or
/// go back to ⌃⇧Space.
struct QuickCaptureSettingsSection: View {
    @State private var controller = QuickCaptureController.shared
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { self.controller.isEnabled }, set: { self.controller.setEnabled($0) })) {
                Text("Quick Capture shortcut")
                Text("Open a small composer from any app to send to a chat.")
            }
            LabeledContent("Shortcut") {
                HStack(spacing: 8) {
                    if self.controller.shortcut != .default {
                        Button("Reset to Default") {
                            self.problem = nil
                            self.controller.reset()
                        }
                        .buttonStyle(.borderless)
                    }
                    ShortcutRecorder(controller: self.controller, problem: self.$problem)
                }
            }
        } header: {
            Text("Quick Capture")
        } footer: {
            if let message = self.problem ?? (self.controller.isEnabled ? self.controller.registrationError : nil) {
                Text(message).foregroundStyle(.red)
            }
        }
    }
}

/// Click, then type a shortcut. Esc cancels, Delete turns the shortcut off, clicking elsewhere
/// cancels. Keys are caught with a local monitor, so no permission is needed; the global hotkey
/// is suspended meanwhile so the current combo can be recorded.
private struct ShortcutRecorder: View {
    let controller: QuickCaptureController
    @Binding var problem: String?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var host = RecorderHost()

    var body: some View {
        Button {
            if self.recording { self.stop() } else { self.start() }
        } label: {
            Text(self.label)
                .font(self.recording ? .body : .body.monospaced())
                .foregroundStyle(self.recording || !self.controller.isEnabled ? .secondary : .primary)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .background(RecorderProbe(host: self.host))
        .accessibilityLabel("Quick Capture shortcut")
        .accessibilityValue(self.label)
        .onDisappear { self.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in self.stop() }
    }

    private var label: String {
        if self.recording { return "Type shortcut…" }
        return self.controller.isEnabled ? self.controller.shortcut.displayString : "None"
    }

    private func start() {
        guard self.monitor == nil else { return }
        self.problem = nil
        self.recording = true
        self.controller.isSuspended = true
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            self.handle(event)
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
        self.recording = false
        self.controller.isSuspended = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else {
            // A click on the recorder itself toggles it through the button's action.
            if let view = self.host.view, event.window === view.window,
               view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { return event }
            self.stop()
            return event
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (UInt32(event.keyCode), modifiers.isEmpty) {
        case (HotKeyShortcut.KeyCode.escape, true):
            self.stop()
            return nil
        case (HotKeyShortcut.KeyCode.delete, true), (HotKeyShortcut.KeyCode.forwardDelete, true):
            self.stop()
            self.controller.setEnabled(false)
            return nil
        default:
            break
        }
        guard let shortcut = HotKeyShortcut(keyCode: event.keyCode, eventModifierFlags: event.modifierFlags.rawValue) else {
            return nil
        }
        if let error = shortcut.validationError {
            self.problem = error
            return nil
        }
        self.problem = nil
        self.stop()
        self.controller.setShortcut(shortcut)
        return nil
    }
}

private final class RecorderHost {
    weak var view: NSView?
}

private struct RecorderProbe: NSViewRepresentable {
    let host: RecorderHost

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        self.host.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
