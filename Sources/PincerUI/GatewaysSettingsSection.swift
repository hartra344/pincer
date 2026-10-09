import PincerKit
import SwiftUI

/// Pincer Settings ▸ Gateways: every Gateway saved on this device, and the one place to change how
/// this device connects to each. Gateway Settings changes the Gateway itself and links here.
struct GatewaysSettingsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.closeAppSettings) private var closeAppSettings
    @State private var picked: UUID?
    @State private var draft = ConnectionDraft()
    @State private var loadedFrom: GatewayProfile?
    /// A row tapped while the draft had unsaved edits, waiting on Discard.
    @State private var pendingPick: UUID?
    @State private var confirmRemove = false
    @State private var confirmApply = false

    var body: some View {
        let menu = self.app.gatewayMenu
        let selected = self.app.gatewayForSettings(self.picked)
        Section {
            ForEach(self.app.gateways) { gateway in
                self.row(gateway, isSelected: gateway.id == selected?.id)
            }
            Button(menu.addActionTitle, systemImage: "plus") {
                self.closeAppSettings { self.app.performGatewayAddAction(menu.addAction) }
            }
            .accessibilityIdentifier("settings-gateways-add")
        } header: {
            Text("Gateways", bundle: .module)
        } footer: {
            Text("Connections are saved on this device. To change a Gateway itself, open Gateway Settings from the gateway menu.", bundle: .module)
        }
        .onAppear { self.takePending(); self.sync(selected) }
        .onChange(of: self.app.pendingAppSettingsGatewayId) { self.takePending() }
        .onChange(of: selected?.profile) { self.sync(self.app.gatewayForSettings(self.picked)) }
        .confirmationDialog(L("Discard unsaved changes?"), isPresented: self.discardBinding) {
            Button(L("Discard Changes"), role: .destructive) {
                let next = self.pendingPick
                self.pendingPick = nil
                self.loadedFrom = nil
                self.picked = next
                self.sync(self.app.gatewayForSettings(next))
            }
        }
        if let selected {
            if selected.profile.isDemo {
                self.demoSections
            } else {
                self.editor(selected)
            }
        }
    }

    private func row(_ gateway: GatewayStore, isSelected: Bool) -> some View {
        Button { self.pick(gateway.id) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: gateway.profile.name).foregroundStyle(.primary)
                    if gateway.profile.isDemo {
                        Text("Demo", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ConnectionStateText(state: gateway.state).font(.caption)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings-gateway-row")
    }

    @ViewBuilder private var demoSections: some View {
        Section {
            Text("The demo runs a simulated Gateway on this device, with sample agents, chats and replies. Nothing is sent anywhere.", bundle: .module)
            Button(L("Connect Your Gateway…")) {
                self.closeAppSettings { self.app.performGatewayAddAction(.connectYourGateway) }
            }
            Button(L("Remove Demo"), role: .destructive) {
                self.closeAppSettings { self.app.leaveDemo() }
            }
        } header: {
            Text("Demo", bundle: .module)
        } footer: {
            Text("Removing the demo deletes its sample chats from this device. Your other Gateways are kept.", bundle: .module)
        }
    }

    @ViewBuilder private func editor(_ gateway: GatewayStore) -> some View {
        let profile = gateway.profile
        let edited = self.draft != ConnectionDraft(profile) || self.draft.secretEdited
        Section {
            LabeledContent(L("Status")) { ConnectionStateText(state: gateway.state) }
            if case let .awaitingPairing(requestId, _) = gateway.state {
                ApprovalInstructions(requestId: requestId)
            }
            Button(L("Reconnect")) { gateway.stop(); gateway.start() }
        } header: {
            Text(verbatim: profile.name)
        }
        ConnectionFields(draft: self.$draft, hasSavedSecret: profile.secret != nil)
        Section {
            HStack {
                Button(L("Revert")) { self.draft = ConnectionDraft(profile) }
                    .disabled(!edited)
                Spacer()
                Button(L("Apply")) { self.requestApply(gateway) }
                    .disabled(!edited || !self.draft.canSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("settings-gateway-apply")
            }
        } footer: {
            Text("Applying saves the connection on this device and reconnects.", bundle: .module)
        }
        Section {
            Button(L("Remove from Pincer…"), role: .destructive) { self.confirmRemove = true }
        }
        .confirmationDialog(L("Remove \(profile.name)?"), isPresented: self.$confirmRemove) {
            Button(L("Remove"), role: .destructive) { self.remove(gateway) }
        } message: {
            Text("The saved token and device pairing token are deleted from this device.", bundle: .module)
        }
        .confirmationDialog(L("Reconnect and discard unsaved settings?"), isPresented: self.$confirmApply) {
            Button(L("Discard \(gateway.settings.changeCount) Changes & Reconnect"), role: .destructive) { self.apply(gateway) }
        } message: {
            Text("Reconnecting to the Gateway starts over from its saved settings.", bundle: .module)
        }
    }

    private var discardBinding: Binding<Bool> {
        Binding(get: { self.pendingPick != nil }, set: { if !$0 { self.pendingPick = nil } })
    }

    private var hasUnsavedEdits: Bool {
        guard let loadedFrom = self.loadedFrom, !loadedFrom.isDemo else { return false }
        return self.draft != ConnectionDraft(loadedFrom) || self.draft.secretEdited
    }

    private func pick(_ id: UUID) {
        guard id != self.app.gatewayForSettings(self.picked)?.id else { return }
        if self.hasUnsavedEdits {
            self.pendingPick = id
        } else {
            self.picked = id
            self.sync(self.app.gatewayForSettings(id))
        }
    }

    private func takePending() {
        if let id = self.app.takePendingAppSettingsGatewayId() { self.pick(id) }
    }

    /// Loads the Gateway's connection, unless the user is in the middle of editing it.
    private func sync(_ gateway: GatewayStore?) {
        guard let profile = gateway?.profile else { return }
        if self.loadedFrom?.id != profile.id || !self.hasUnsavedEdits {
            self.draft = ConnectionDraft(profile)
        }
        self.loadedFrom = profile
    }

    private func requestApply(_ gateway: GatewayStore) {
        if gateway.settings.hasChanges { self.confirmApply = true } else { self.apply(gateway) }
    }

    private func apply(_ gateway: GatewayStore) {
        let existing = gateway.profile
        let profile = self.draft.profile(id: existing.id)
        let secret = self.draft.authMode == .none ? nil : self.draft.secret
        self.app.update(profile, secret: self.draft.secretEdited ? secret : existing.secret,
                        credentialsChanged: self.draft.credentialsChanged(from: existing))
        self.draft.secret = ""
        self.loadedFrom = profile
    }

    private func remove(_ gateway: GatewayStore) {
        let id = gateway.id
        self.picked = nil
        self.loadedFrom = nil
        if self.app.gateways.count == 1 {
            // The last one: Welcome shows next, so Settings gets out of its way first.
            self.closeAppSettings { self.app.remove(id) }
        } else {
            self.app.remove(id)
        }
    }
}
