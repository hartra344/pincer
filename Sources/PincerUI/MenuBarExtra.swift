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
        // Not `self.$enabled`: the extra writes the binding back on every update, and an
        // unconditional @AppStorage write re-triggers that update forever (#119).
        MenuBarExtra(isInserted: Binding(get: { self.enabled }, set: { MenuBarSettings().setEnabled($0) })) {
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
    var clock = MenuBarClock.shared

    private static let hasAlertSymbol = NSImage(systemSymbolName: MenuBarInbox.alertSymbol, accessibilityDescription: nil) != nil

    var body: some View {
        let inbox = MenuBarInbox(app: self.app, now: self.clock.now)
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
    var clock = MenuBarClock.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let inbox = MenuBarInbox(app: self.app, now: self.clock.now)
        Button(QuickCaptureController.shared.menuTitle) { QuickCaptureController.shared.show() }
        Button(L("Open Pincer")) { self.showMainWindow() }
        Divider()
        self.section("Needs You", inbox.needsYou, overflow: inbox.needsYouOverflow)
        self.section("Running", inbox.running, overflow: inbox.runningOverflow)
        self.section("Unread", inbox.unread, overflow: inbox.unreadOverflow)
        if inbox.isCaughtUp {
            Button(L("You're all caught up")) {}
                .disabled(true)
        }
        Divider()
        Section(L("Gateways")) {
            if inbox.gateways.isEmpty {
                Button(L("No gateways yet")) {}
                    .disabled(true)
            }
            ForEach(inbox.gateways) { status in
                Button {
                    self.open(Notifier.Target(gatewayId: status.id, sessionKey: ""))
                } label: {
                    Label(status.title, systemImage: status.symbol)
                }
            }
            // #134: finish setting up the selected gateway from here too.
            if let gateway = self.app.selectedGateway, !gateway.profile.isDemo, !gateway.setup.progress.completed {
                Button("Set Up Gateway…") {
                    gateway.setup.present()
                    self.showMainWindow()
                }
                .disabled(!gateway.state.isConnected)
            }
            Button("Add Gateway…") {
                self.app.firstRun.present()
                self.showMainWindow()
            }
        }
        Divider()
        Button(L("Settings…")) {
            NSApp.activate()
            self.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button(L("Quit Pincer")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder private func section(_ title: String, _ items: [MenuBarInbox.Item], overflow: Int) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button(item.title) { self.open(item.target) }
                }
                if overflow > 0 {
                    Button(L("\(overflow) more…")) { self.showMainWindow() }
                }
            }
        }
    }

    /// Selects the chat first, so a window created by `showMainWindow` starts on it.
    private func open(_ target: Notifier.Target) {
        self.app.open(self.app.route(for: target), verifySession: false)
        self.showMainWindow()
    }

    private func showMainWindow() {
        let controller = QuickCaptureController.shared
        if controller.openWindow == nil { controller.openWindow = self.openWindow }
        controller.showMainWindow()
    }
}
#endif
