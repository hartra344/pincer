#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// The optional menu bar item: Quick Capture, the inbox, each Gateway's status, Settings and Quit.
/// Turned on in Settings → General; ⌘-dragging it out of the menu bar turns the setting off.
struct PincerMenuBar: Scene {
    let app: AppModel
    @AppStorage(MenuBarSettings.enabledKey) private var enabled = false

    var body: some Scene {
        MenuBarExtra(isInserted: self.$enabled) {
            MenuBarContent(app: self.app)
        } label: {
            MenuBarLabel(app: self.app)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The template icon, with the unread plus needs-you count beside it.
struct MenuBarLabel: View {
    let app: AppModel

    private static let hasAlertSymbol = NSImage(systemSymbolName: MenuBarInbox.alertSymbol, accessibilityDescription: nil) != nil

    var body: some View {
        let inbox = MenuBarInbox(app: self.app)
        HStack(spacing: 3) {
            Image(systemName: inbox.needsYouCount > 0 && Self.hasAlertSymbol ? MenuBarInbox.alertSymbol : MenuBarInbox.symbol)
            if let badge = inbox.badgeText {
                Text(badge).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inbox.accessibilityLabel)
    }
}

/// The menu. Everything it lists comes from `MenuBarInbox`; rows only open things.
struct MenuBarContent: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let inbox = MenuBarInbox(app: self.app)
        Button(QuickCaptureController.shared.menuTitle) { QuickCaptureController.shared.show() }
        Button("Open Pincer") { self.showMainWindow() }
        Divider()
        self.section("Needs You", inbox.needsYou, overflow: inbox.needsYouOverflow)
        self.section("Running", inbox.running, overflow: inbox.runningOverflow)
        self.section("Unread", inbox.unread, overflow: inbox.unreadOverflow)
        if inbox.isCaughtUp {
            Button("You're all caught up") {}
                .disabled(true)
        }
        Divider()
        Section("Gateways") {
            if inbox.gateways.isEmpty {
                Button("No gateways yet") {}
                    .disabled(true)
            }
            ForEach(inbox.gateways) { status in
                Button {
                    self.open(Notifier.Target(gatewayId: status.id, sessionKey: ""))
                } label: {
                    Label(status.title, systemImage: status.symbol)
                }
            }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            self.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Quit Pincer") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder private func section(_ title: String, _ items: [MenuBarInbox.Item], overflow: Int) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button(item.title) { self.open(item.target) }
                }
                if overflow > 0 {
                    Button("\(overflow) more…") { self.showMainWindow() }
                }
            }
        }
    }

    /// Selects the chat first, so a window created by `showMainWindow` starts on it.
    private func open(_ target: Notifier.Target) {
        self.app.open(target)
        self.showMainWindow()
    }

    private func showMainWindow() {
        let controller = QuickCaptureController.shared
        if controller.openWindow == nil { controller.openWindow = self.openWindow }
        controller.showMainWindow()
    }
}
#endif
