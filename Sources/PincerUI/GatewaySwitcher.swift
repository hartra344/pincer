import PincerKit
import SwiftUI

/// The sidebar's gateway button: names the Gateway you're on and switches, adds or reconnects.
/// Its own view, so a status change re-renders only this label, not the chat list.
struct GatewaySwitcherButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @Environment(\.openAppSettings) private var openAppSettings
    @Environment(\.openAutomations) private var openAutomations

    var body: some View {
        let menu = self.app.gatewayMenu
        Menu {
            Section {
                @Bindable var app = self.app
                Picker(L("Gateway"), selection: $app.selectedGatewayId) {
                    ForEach(menu.entries) { entry in
                        Text(verbatim: entry.menuTitle).tag(Optional(entry.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Button(menu.addActionTitle) { self.app.performGatewayAddAction(menu.addAction) }
                if self.app.demoGateway != nil {
                    Button(L("Leave Demo")) { self.app.leaveDemo() }
                }
                Button(L("Manage Gateways…")) { self.openAppSettings(.gateways, gateway: self.app.selectedGatewayId) }
            }
            if let gateway = self.app.selectedGateway {
                Section {
                    ForEach(GatewayMenuModel.gatewayActions) { action in
                        Button(action.title) { self.perform(action, on: gateway) }
                            .disabled(action.needsConnection && !gateway.state.isConnected)
                            #if os(iOS)
                            // macOS binds it in the Gateway menu instead.
                            .keyboardShortcut(action == .gatewaySettings
                                ? ShortcutStore.shared.activeCombo(for: .gatewaySettings)?.keyboardShortcut : nil)
                            #endif
                    }
                }
            }
        } label: {
            self.label(menu)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityHint(L("Gateway menu"))
        .accessibilityIdentifier("sidebar-gateway-switcher")
    }

    private func perform(_ action: GatewayMenuModel.GatewayAction, on gateway: GatewayStore) {
        switch action {
        case .gatewaySettings: self.openGatewaySettings(gateway)
        case .automations: self.openAutomations(gateway)
        case .setupAssistant: gateway.setup.present()
        case .reconnect: gateway.stop(); gateway.start()
        }
    }

    @ViewBuilder private func label(_ menu: GatewayMenuModel) -> some View {
        let name = menu.selected?.name ?? L("Gateways")
        // The demo is always effectively connected, so its badge says enough.
        let status = menu.showsDemoBadge ? "" : (menu.selected?.statusText ?? "")
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                self.nameText(name)
                self.statusText(status)
                self.badge(menu)
                Spacer(minLength: 0)
                self.chevron
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        self.nameText(name)
                        self.badge(menu)
                    }
                    self.statusText(status)
                }
                Spacer(minLength: 0)
                self.chevron
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(menu.selected?.accessibilityLabel ?? name)
        .accessibilityAddTraits(.isButton)
    }

    private func nameText(_ name: String) -> some View {
        Text(name)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
    }

    @ViewBuilder private func statusText(_ status: String) -> some View {
        if !status.isEmpty {
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func badge(_ menu: GatewayMenuModel) -> some View {
        if menu.showsDemoBadge {
            Text(L("DEMO"))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

extension AppModel {
    /// Connect Your Gateway… (from the demo) or Add Gateway….
    func performGatewayAddAction(_ action: GatewayMenuModel.AddAction) {
        switch action {
        case .connectYourGateway:
            self.leaveDemo(connect: true)
        case .addGateway:
            self.firstRun.present()
        }
        #if os(macOS)
        QuickCaptureController.shared.showMainWindow()
        #endif
    }
}

/// Gateway menu (macOS) and Next/Previous Gateway (iPad hardware keyboard).
struct GatewayCommands: Commands {
    let app: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some Commands {
        CommandMenu(L("Gateway")) {
            let menu = self.app.gatewayMenu
            #if os(macOS)
            @Bindable var app = self.app
            Picker(L("Gateway"), selection: $app.selectedGatewayId) {
                ForEach(menu.entries) { entry in
                    Text(verbatim: entry.menuTitle).tag(Optional(entry.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            #endif
            Button(L("Next Gateway")) { self.app.selectNextGateway() }
                .shortcut(.nextGateway)
                .disabled(!menu.canCycle)
            Button(L("Previous Gateway")) { self.app.selectPreviousGateway() }
                .shortcut(.previousGateway)
                .disabled(!menu.canCycle)
            #if os(macOS)
            Divider()
            Button(menu.addActionTitle) { self.app.performGatewayAddAction(menu.addAction) }
            if self.app.demoGateway != nil {
                Button(L("Leave Demo")) { self.app.leaveDemo() }
            }
            Button(L("Manage Gateways…")) {
                self.app.pendingAppSettingsGatewayId = self.app.selectedGatewayId
                self.app.pendingAppSettingsPage = .gateways
                self.openSettings()
            }
            let gateway = self.app.selectedGateway
            // Same steps as RootView's settingsOpener / automationsOpener; Commands can't read the scene's environment.
            Button(L("Gateway Settings…")) {
                guard let gateway else { return }
                gateway.settings.requestedRoutes = []
                gateway.settings.requestedDestination = nil
                self.openWindow(id: "gateway-settings", value: gateway.id)
            }
            .shortcut(.gatewaySettings)
            .disabled(gateway == nil)
            Button(L("Automations…")) {
                guard let gateway else { return }
                self.openWindow(id: "automations", value: gateway.id)
            }
            .disabled(gateway == nil)
            Button(L("Setup Assistant…")) { gateway?.setup.present() }
                .disabled(!(gateway?.state.isConnected ?? false))
            Button(L("Reconnect")) { gateway?.stop(); gateway?.start() }
                .disabled(gateway == nil)
            #endif
        }
    }
}
