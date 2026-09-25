import PincerKit
import SwiftUI

/// Add or edit a Gateway connection.
struct ConnectionSheet: View {
    let existing: GatewayProfile?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Home"
    @State private var url = ""
    @State private var authMode: GatewayProfile.AuthMode = .token
    @State private var secret = ""
    @State private var secretEdited = false
    @State private var fingerprint = ""
    @State private var manageSettings = false
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                if self.existing?.isDemo == true {
                    Section {
                        Text("The demo runs a simulated Gateway on this device, with sample agents, chats and replies. Nothing is sent anywhere.")
                    }
                } else {
                    Section {
                        TextField("Name", text: self.$name)
                        TextField("Gateway URL", text: self.$url, prompt: Text("wss://home.tailnet-name.ts.net"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        if let error = self.urlError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else if self.url.lowercased().hasPrefix("ws://"), self.url.lowercased().contains(".ts.net") {
                            Text("Tailscale Serve uses HTTPS, so this should usually be wss://. Use ws:// only with the tailnet IP and Gateway port.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("Use your Tailscale Serve name (wss://…ts.net) or tailnet IP (ws://100.x.y.z:18789). Plain ws:// is only allowed for Tailscale, LAN and loopback addresses.")
                    }

                    Section("Authentication") {
                        Picker("Method", selection: self.$authMode) {
                            ForEach(GatewayProfile.AuthMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        if self.authMode != .none {
                            SecureField(self.authMode == .token ? "Gateway token" : "Gateway password", text: self.$secret,
                                        prompt: Text(self.existing != nil && !self.secretEdited ? "Saved in Keychain" : "Required for first pairing"))
                                .onChange(of: self.secret) { self.secretEdited = true }
                        }
                    }

                    Section {
                        TextField("TLS certificate SHA-256", text: self.$fingerprint, prompt: Text("Optional pin, hex"))
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                        Toggle(isOn: self.$manageSettings) {
                            Text("Manage Gateway settings")
                            Text("Also asks for admin access, so you can change the Gateway's config and plugins. The Gateway host approves this device again.")
                        }
                    } header: {
                        Text("Advanced")
                    } footer: {
                        Text("Pincer connects as an operator only. It never runs a Gateway, never registers as a node, and stores secrets in the Keychain.")
                    }
                }

                if self.existing == nil {
                    Section {
                        Button("Try the Demo", systemImage: "play.circle") {
                            self.app.openDemo()
                            self.dismiss()
                        }
                    } footer: {
                        Text("No Gateway yet? Explore Pincer with sample agents and chats. Nothing leaves this device.")
                    }
                }

                if let existing {
                    Section {
                        Button("Remove Gateway", role: .destructive) { self.confirmRemove = true }
                            .confirmationDialog("Remove \(existing.name)?", isPresented: self.$confirmRemove) {
                                Button("Remove", role: .destructive) {
                                    self.app.remove(existing.id)
                                    self.dismiss()
                                }
                            } message: {
                                Text("The saved token and device pairing token are deleted from this device.")
                            }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(self.existing == nil ? "Add Gateway" : "Edit Gateway")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(self.existing == nil ? "Connect" : "Save", action: self.save)
                        .disabled(self.url.isEmpty || self.urlError != nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
        .onAppear {
            guard let existing else { return }
            self.name = existing.name
            self.url = existing.url
            self.authMode = existing.authMode
            self.fingerprint = existing.tlsFingerprint ?? ""
            self.manageSettings = existing.manageSettings
            self.secretEdited = false
        }
    }

    private var draft: GatewayProfile {
        GatewayProfile(
            id: self.existing?.id ?? UUID(),
            name: self.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Gateway" : self.name,
            url: self.url.trimmingCharacters(in: .whitespacesAndNewlines),
            authMode: self.authMode,
            tlsFingerprint: self.fingerprint.nilIfBlank,
            manageSettings: self.manageSettings)
    }

    private var urlError: String? {
        guard !self.url.isEmpty, !self.draft.isDemo else { return nil }
        do {
            _ = try self.draft.resolvedURL()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func save() {
        let profile = self.draft
        let secret = self.authMode == .none ? nil : self.secret
        if let existing {
            let changed = self.secretEdited || existing.url != profile.url || existing.authMode != profile.authMode
            self.app.update(profile, secret: self.secretEdited ? secret : existing.secret, credentialsChanged: changed)
        } else {
            self.app.add(profile, secret: secret)
        }
        self.dismiss()
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
