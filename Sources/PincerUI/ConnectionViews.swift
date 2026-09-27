import PincerKit
import SwiftUI

/// The editable fields of a Gateway connection.
struct ConnectionDraft: Equatable {
    var name = "Home"
    var url = ""
    var authMode: GatewayProfile.AuthMode = .token
    /// A newly entered token or password; empty keeps the one saved in the Keychain.
    var secret = ""
    var fingerprint = ""
    var access: GatewayProfile.AccessLevel = .standard

    init() {}

    init(_ profile: GatewayProfile) {
        self.name = profile.name
        self.url = profile.url
        self.authMode = profile.authMode
        self.fingerprint = profile.tlsFingerprint ?? ""
        self.access = profile.access
    }

    func profile(id: UUID) -> GatewayProfile {
        GatewayProfile(
            id: id,
            name: self.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Gateway" : self.name,
            url: self.url.trimmingCharacters(in: .whitespacesAndNewlines),
            authMode: self.authMode,
            tlsFingerprint: self.fingerprint.nilIfBlank,
            access: self.access)
    }

    var urlError: String? {
        let profile = self.profile(id: UUID())
        guard !self.url.isEmpty, !profile.isDemo else { return nil }
        do {
            _ = try profile.resolvedURL()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var secretEdited: Bool { !self.secret.isEmpty }

    var canSave: Bool { !self.url.isEmpty && self.urlError == nil }

    /// Whether saving should drop the paired device token and use the new secret.
    func credentialsChanged(from existing: GatewayProfile) -> Bool {
        self.secretEdited || existing.url != self.url.trimmingCharacters(in: .whitespacesAndNewlines)
            || existing.authMode != self.authMode
    }
}

/// Address, authentication, access and TLS pin for a Gateway.
struct ConnectionFields: View {
    @Binding var draft: ConnectionDraft
    /// A secret is already saved in the Keychain.
    var hasSavedSecret: Bool

    var body: some View {
        Section {
            TextField("Name", text: self.$draft.name)
            TextField("Gateway URL", text: self.$draft.url, prompt: Text("wss://home.tailnet-name.ts.net"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            if let error = self.draft.urlError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if self.draft.url.lowercased().hasPrefix("ws://"), self.draft.url.lowercased().contains(".ts.net") {
                Text("Tailscale Serve uses HTTPS, so this should usually be wss://. Use ws:// only with the tailnet IP and Gateway port.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } footer: {
            Text("Use your Tailscale Serve name (wss://…ts.net) or tailnet IP (ws://100.x.y.z:18789). Plain ws:// is only allowed for Tailscale, LAN and loopback addresses.")
        }

        Section("Authentication") {
            Picker("Method", selection: self.$draft.authMode) {
                ForEach(GatewayProfile.AuthMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if self.draft.authMode != .none {
                SecureField(self.draft.authMode == .token ? "Gateway token" : "Gateway password", text: self.$draft.secret,
                    prompt: Text(self.hasSavedSecret && !self.draft.secretEdited ? "Saved in Keychain" : "Required for first pairing"))
            }
        }

        Section {
            Picker("Access", selection: self.$draft.access) {
                ForEach(GatewayProfile.AccessLevel.allCases) { Text($0.label).tag($0) }
            }
            #if os(iOS)
            .pickerStyle(.segmented)
            #else
            .pickerStyle(.radioGroup)
            #endif
        } header: {
            Text("Access")
        } footer: {
            Text(self.draft.access.detail)
        }

        Section {
            TextField("TLS certificate SHA-256", text: self.$draft.fingerprint, prompt: Text("Optional pin, hex"))
                .font(.body.monospaced())
                .autocorrectionDisabled()
        } header: {
            Text("Security")
        } footer: {
            Text("Pincer connects as an operator only. It never runs a Gateway, never registers as a node, and stores secrets in the Keychain.")
        }
    }
}

/// Add a Gateway.
struct ConnectionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionDraft()

    var body: some View {
        NavigationStack {
            Form {
                ConnectionFields(draft: self.$draft, hasSavedSecret: false)
                Section {
                    Button("Try the Demo", systemImage: "play.circle") {
                        self.app.openDemo()
                        self.dismiss()
                    }
                } footer: {
                    Text("No Gateway yet? Explore Pincer with sample agents and chats. Nothing leaves this device.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Gateway")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: self.save).disabled(!self.draft.canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
    }

    private func save() {
        let profile = self.draft.profile(id: UUID())
        self.app.add(profile, secret: self.draft.authMode == .none ? nil : self.draft.secret)
        self.dismiss()
    }
}

/// Gateway Settings → Connection: this device's side of the connection. Unlike the Gateway's
/// own settings, these are saved on this device, and applying them reconnects.
struct ConnectionPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionDraft()
    @State private var loadedFrom: GatewayProfile?
    @State private var confirmRemove = false
    @State private var confirmApply = false

    var body: some View {
        let profile = self.gateway.profile
        let edited = self.draft != ConnectionDraft(profile) || self.draft.secretEdited
        Form {
            self.statusSection
            if profile.isDemo {
                Section {
                    Text("The demo runs a simulated Gateway on this device, with sample agents, chats and replies. Nothing is sent anywhere.")
                }
            } else {
                ConnectionFields(draft: self.$draft, hasSavedSecret: profile.secret != nil)
            }
            Section {
                Button("Reconnect") { self.gateway.stop(); self.gateway.start() }
                Button("Remove Gateway…", role: .destructive) { self.confirmRemove = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
        .toolbar {
            if !profile.isDemo {
                #if os(macOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    if edited {
                        Button("Revert") { self.draft = ConnectionDraft(profile) }
                    }
                    Button("Apply", action: self.requestApply)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!edited || !self.draft.canSave)
                        .help("Save the connection on this device and reconnect")
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: self.requestApply)
                        .disabled(!edited || !self.draft.canSave)
                }
                if edited {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Revert") { self.draft = ConnectionDraft(profile) }
                    }
                }
                #endif
            }
        }
        .onAppear(perform: self.sync)
        .onChange(of: profile) { self.sync() }
        .confirmationDialog("Remove \(profile.name)?", isPresented: self.$confirmRemove) {
            Button("Remove", role: .destructive) {
                self.app.remove(profile.id)
                self.dismiss()
            }
        } message: {
            Text("The saved token and device pairing token are deleted from this device.")
        }
        .confirmationDialog("Reconnect and discard unsaved settings?", isPresented: self.$confirmApply) {
            Button("Discard \(self.gateway.settings.changeCount) Changes & Reconnect", role: .destructive, action: self.apply)
        } message: {
            Text("Reconnecting to the Gateway starts over from its saved settings.")
        }
    }

    @ViewBuilder private var statusSection: some View {
        let settings = self.gateway.settings
        Section {
            LabeledContent("Status") { ConnectionStateText(state: self.gateway.state) }
            if case let .awaitingPairing(requestId, _) = self.gateway.state {
                ApprovalInstructions(requestId: requestId)
            } else if self.gateway.profile.access == .admin, self.gateway.state.isConnected, !settings.canEdit {
                Text("The Gateway hasn't granted Full Management to this device yet.")
                    .foregroundStyle(.orange)
                ApprovalInstructions(requestId: nil)
            }
        }
    }

    /// Loads the profile, unless the user is in the middle of editing it.
    private func sync() {
        let profile = self.gateway.profile
        if self.loadedFrom == nil || self.draft == ConnectionDraft(self.loadedFrom!) {
            self.draft = ConnectionDraft(profile)
        }
        self.loadedFrom = profile
    }

    private func requestApply() {
        if self.gateway.settings.hasChanges { self.confirmApply = true } else { self.apply() }
    }

    private func apply() {
        let existing = self.gateway.profile
        let profile = self.draft.profile(id: existing.id)
        let secret = self.draft.authMode == .none ? nil : self.draft.secret
        self.app.update(profile, secret: self.draft.secretEdited ? secret : existing.secret,
                        credentialsChanged: self.draft.credentialsChanged(from: existing))
        self.draft.secret = ""
    }
}

/// What to run on the Gateway host to approve this device.
struct ApprovalInstructions: View {
    let requestId: String?
    @State private var copied = false

    var body: some View {
        let command = self.requestId.map { "openclaw devices approve \($0)" } ?? "openclaw devices list\nopenclaw devices approve <requestId>"
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve this device on the Gateway host:").font(.callout).foregroundStyle(.secondary)
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            HStack {
                Button(self.copied ? "Copied" : "Copy Command", systemImage: self.copied ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(command)
                    self.copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        self.copied = false
                    }
                }
                .buttonStyle(.borderless)
                Spacer()
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Shown while the Gateway host hasn't approved this device yet.
struct PairingView: View {
    let requestId: String?
    let deviceId: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
            Text("Approve Pincer on your Gateway host")
                .font(.title2.bold())
            Text("For your security, new devices must be approved on the machine running OpenClaw. Run this there:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            let command = self.requestId.map { "openclaw devices approve \($0)" } ?? "openclaw devices list"
            Text(command)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: 440)
                .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contextMenu {
                    Button("Copy Command", systemImage: "doc.on.doc") { self.copy(command) }
                }
            Button {
                self.copy(command)
            } label: {
                Label(self.copied ? "Copied" : "Copy Command",
                      systemImage: self.copied ? "checkmark" : "doc.on.doc")
            }
            .glassProminentButton()
            .controlSize(.large)
            .tint(self.copied ? .green : self.theme.accent)
            .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 4) {
                Text("Device ID").font(.caption).foregroundStyle(.secondary)
                Text(self.deviceId.prefix(16) + "…")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking every few seconds…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var copied = false

    private func copy(_ command: String) {
        Clipboard.copy(command)
        self.copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.copied = false
        }
    }
}

struct FailedView: View {
    let message: String
    let edit: () -> Void
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        ContentUnavailableView {
            Label("Can’t connect to \(self.gateway.profile.name)", systemImage: "exclamationmark.octagon")
        } description: {
            Text(self.message)
        } actions: {
            HStack {
                Button("Edit Connection…", action: self.edit)
                    .glassButton()
                Button("Try Again") {
                    self.gateway.stop()
                    self.gateway.start()
                }
                .glassProminentButton()
            }
            .controlSize(.large)
        }
    }
}
