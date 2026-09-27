import PincerKit
import SwiftUI

/// Gateway Settings → Devices: operator devices paired with the Gateway and devices waiting to pair
/// (`device.pair.*`). Listing needs `operator.pairing`; approving, rejecting, renaming and removing
/// need Full Management. `device.pair.requested` / `resolved` / `changed` events keep it current.
struct DevicesPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var approving: PendingDeviceRequest?
    @State private var rejecting: PendingDeviceRequest?
    @State private var removing: PairedDevice?
    @State private var renaming: PairedDevice?
    @State private var renameText = ""

    private var model: DeviceManagementModel { self.gateway.devices }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if !connected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to manage its devices."))
            } else if !model.supported {
                ContentUnavailableView("Devices Aren't Available", systemImage: "laptopcomputer.and.iphone",
                                       description: Text("This Gateway doesn't support device pairing. Update OpenClaw to manage devices here."))
            } else if model.needsAccess {
                DeviceAccessNeeded()
            } else {
                self.list(model)
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            if connected, model.supported, !model.needsAccess {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.loadState.isRunning)
                        .help("Refresh")
                }
            }
        }
        .task(id: connected) {
            if connected { await model.load() }
        }
        .confirmationDialog(self.approving.map { "Approve \($0.title)?" } ?? "", isPresented: Binding(
            get: { self.approving != nil }, set: { if !$0 { self.approving = nil } }
        ), titleVisibility: .visible, presenting: self.approving) { request in
            Button("Approve") { Task { await model.approve(request) } }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(DevicesUI.approveMessage(request))
        }
        .confirmationDialog(self.rejecting.map { "Reject \($0.title)?" } ?? "", isPresented: Binding(
            get: { self.rejecting != nil }, set: { if !$0 { self.rejecting = nil } }
        ), titleVisibility: .visible, presenting: self.rejecting) { request in
            Button("Reject", role: .destructive) { Task { await model.reject(request) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The device won't be able to connect. It can ask again.")
        }
        .confirmationDialog(self.removing.map { model.isSelf($0) ? "Remove This Device?" : "Remove \($0.title)?" } ?? "",
                            isPresented: Binding(get: { self.removing != nil }, set: { if !$0 { self.removing = nil } }),
                            titleVisibility: .visible, presenting: self.removing) { device in
            Button(model.isSelf(device) ? "Remove and Disconnect" : "Remove", role: .destructive) {
                Task { await model.remove(device) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text(model.isSelf(device) ? DeviceManagementModel.selfRemoveWarning
                : "\(device.title) loses access right away and is disconnected. To use it again, it has to pair again.")
        }
        .alert("Rename Device", isPresented: Binding(
            get: { self.renaming != nil }, set: { if !$0 { self.renaming = nil } }
        ), presenting: self.renaming) { device in
            TextField("Name", text: self.$renameText)
            Button("Save") {
                let label = self.renameText
                Task { await model.rename(device, to: label) }
            }
            .disabled(self.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The name is shown to every operator of this gateway (up to \(DeviceManagementModel.maxLabelLength) characters).")
        }
        .overlay(alignment: .bottom) { DeviceNotice(model: model) }
    }

    private func list(_ model: DeviceManagementModel) -> some View {
        List {
            if let reason = model.readOnlyReason {
                Section {
                    Label(reason, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                    Button("Open Connection") { self.navigator.destination = .connection }
                }
            }
            if let error = model.loadState.error, model.hasLoaded {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    Button("Try Again") { Task { await model.refresh() } }
                }
            }
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { request in
                        PendingDeviceRow(request: request, model: model,
                                         approve: { self.approving = request }, reject: { self.rejecting = request })
                    }
                } header: {
                    Text("Waiting for Approval")
                } footer: {
                    Text("Check the fingerprint against the device before approving: on the device, it's the device id shown while it waits.")
                }
            }
            if !model.paired.isEmpty {
                Section {
                    ForEach(model.paired) { device in
                        PairedDeviceRow(device: device, model: model,
                                        rename: {
                                            self.renameText = device.operatorLabel ?? device.displayName ?? ""
                                            self.renaming = device
                                        },
                                        remove: { self.removing = device })
                    }
                } header: {
                    Text("Paired Devices")
                } footer: {
                    Text("Removing a device revokes its access and disconnects it.")
                }
            }
        }
        #if os(iOS)
        .refreshable { await model.refresh() }
        #endif
        .overlay {
            if model.pending.isEmpty, model.paired.isEmpty {
                if !model.hasLoaded {
                    ProgressView()
                } else if model.loadState.error == nil {
                    ContentUnavailableView("No Devices", systemImage: "laptopcomputer.and.iphone",
                                           description: Text("Devices that pair with this gateway show up here."))
                }
            }
        }
    }
}

// MARK: Rows

private struct PendingDeviceRow: View {
    let request: PendingDeviceRequest
    let model: DeviceManagementModel
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        let operation = self.model.operation(for: self.request)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.request.title).font(.headline).lineLimit(1)
                if self.request.isRepair { DeviceTag(text: "Re-pair", color: .orange) }
                if self.model.isSelf(self.request) { DeviceTag(text: "This Device", color: .accentColor) }
                Spacer(minLength: 8)
                #if os(macOS)
                self.buttons(busy: operation.isRunning)
                #endif
            }
            if !self.request.subtitle.isEmpty {
                Text(self.request.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            FingerprintText(deviceId: self.request.deviceId)
            Text(DevicesUI.accessLine(roles: self.request.roles, scopes: self.request.scopes))
                .font(.caption)
                .foregroundStyle(.secondary)
            if self.request.requestsNodeRole {
                Label("Asks to run commands for agents (node role).", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let requestedAt = self.request.requestedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Requested \(DeviceFingerprint.ago(requestedAt, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(requestedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            DisclosureGroup("Details") {
                DeviceDetails(deviceId: self.request.deviceId, clientId: self.request.clientId,
                              clientMode: self.request.clientMode, origin: self.request.browserOrigin,
                              scopes: self.request.scopes, requestId: self.request.requestId)
            }
            .font(.caption)
            if let error = operation.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            #if os(iOS)
            HStack {
                Spacer()
                self.buttons(busy: operation.isRunning)
            }
            .padding(.top, 4)
            #endif
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Device ID", systemImage: "doc.on.doc") { Clipboard.copy(self.request.deviceId) }
            Button("Copy Request ID", systemImage: "number") { Clipboard.copy(self.request.requestId) }
        }
    }

    @ViewBuilder private func buttons(busy: Bool) -> some View {
        if busy { ProgressView().controlSize(.small) }
        if self.model.canManage {
            Button("Reject", action: self.reject)
                .buttonStyle(.bordered)
                .disabled(busy)
                .accessibilityLabel("Reject \(self.request.title)")
            Button("Approve", action: self.approve)
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                .accessibilityLabel("Approve \(self.request.title)")
        }
    }
}

private struct PairedDeviceRow: View {
    let device: PairedDevice
    let model: DeviceManagementModel
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        let operation = self.model.operation(for: self.device)
        let isSelf = self.model.isSelf(self.device)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(self.device.connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(self.device.connected ? "Connected" : "Not connected")
                Text(self.device.title).font(.headline).lineLimit(1)
                if isSelf { DeviceTag(text: "This Device", color: .accentColor) }
                if self.device.isNode { DeviceTag(text: "Node", color: .purple) }
                Spacer(minLength: 8)
                if operation.isRunning { ProgressView().controlSize(.small) }
                if self.model.canManage { self.menu(busy: operation.isRunning) }
            }
            if !self.device.subtitle.isEmpty {
                Text(self.device.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            FingerprintText(deviceId: self.device.deviceId)
            Text(DevicesUI.accessLine(roles: self.device.roles, scopes: self.device.effectiveScopes))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastActive = self.device.lastActive, !self.device.connected {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Last seen \(DeviceFingerprint.ago(lastActive, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(lastActive.formatted(date: .abbreviated, time: .shortened))
                }
            }
            DisclosureGroup("Details") {
                DeviceDetails(deviceId: self.device.deviceId, clientId: self.device.clientId,
                              clientMode: self.device.clientMode, origin: nil,
                              scopes: self.device.effectiveScopes, requestId: nil)
                if let label = self.device.operatorLabel, let name = self.device.displayName, label != name {
                    LabeledContent("Device name", value: name).font(.caption)
                }
                if let via = self.device.approvedViaLabel { LabeledContent("Approval", value: via).font(.caption) }
                if let approvedAt = self.device.approvedAt {
                    LabeledContent("Approved", value: approvedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
                ForEach(self.device.tokens, id: \.role) { token in
                    LabeledContent("\(token.role.capitalized) token", value: DevicesUI.tokenLine(token)).font(.caption)
                }
            }
            .font(.caption)
            if let error = operation.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Device ID", systemImage: "doc.on.doc") { Clipboard.copy(self.device.deviceId) }
            if self.model.canManage {
                if self.model.canRename { Button("Rename…", systemImage: "pencil", action: self.rename) }
                Button(isSelf ? "Remove This Device…" : "Remove…", systemImage: "trash", role: .destructive, action: self.remove)
            }
        }
    }

    private func menu(busy: Bool) -> some View {
        Menu {
            if self.model.canRename { Button("Rename…", systemImage: "pencil", action: self.rename) }
            Button(self.model.isSelf(self.device) ? "Remove This Device…" : "Remove…", systemImage: "trash",
                   role: .destructive, action: self.remove)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .accessibilityLabel("Actions for \(self.device.title)")
    }
}

// MARK: Pieces

private struct DeviceTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(self.text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(self.color.opacity(0.15), in: Capsule())
            .foregroundStyle(self.color)
    }
}

private struct FingerprintText: View {
    let deviceId: String

    var body: some View {
        Label {
            Text(DeviceFingerprint.format(self.deviceId))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: "touchid").font(.caption)
        }
        .foregroundStyle(.secondary)
        .help("Device fingerprint (SHA-256 of its public key): \(self.deviceId)")
        .accessibilityLabel("Fingerprint \(DeviceFingerprint.short(self.deviceId))")
    }
}

private struct DeviceDetails: View {
    let deviceId: String
    let clientId: String?
    let clientMode: String?
    let origin: String?
    let scopes: [String]
    let requestId: String?

    var body: some View {
        LabeledContent("Device ID") {
            Text(self.deviceId).font(.caption.monospaced()).textSelection(.enabled)
        }
        .font(.caption)
        if let clientId { LabeledContent("Client", value: [clientId, self.clientMode].compactMap(\.self).joined(separator: " · ")).font(.caption) }
        if let origin { LabeledContent("Origin", value: origin).font(.caption) }
        if !self.scopes.isEmpty {
            LabeledContent("Scopes") {
                Text(self.scopes.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
            }
            .font(.caption)
        }
        if let requestId {
            LabeledContent("Request ID") { Text(requestId).font(.caption.monospaced()).textSelection(.enabled) }
                .font(.caption)
        }
    }
}

/// The page's one-off message ("already handled"), like Pairing Requests'.
private struct DeviceNotice: View {
    let model: DeviceManagementModel

    var body: some View {
        if let notice = self.model.notice {
            Text(notice.text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule())
                .padding(.horizontal)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation { self.model.clearNotice() } }
                .task(id: notice.id) {
                    AccessibilityNotification.Announcement(notice.text).post()
                    try? await Task.sleep(for: .seconds(4))
                    if self.model.notice?.id == notice.id { withAnimation { self.model.clearNotice() } }
                }
        }
    }
}

/// Listing devices needs `operator.pairing`, which Pincer gets with Full Management.
private struct DeviceAccessNeeded: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        ContentUnavailableView {
            Label("Full Management Needed", systemImage: "lock")
        } description: {
            Text(DeviceManagementModel.needsAccessMessage)
        } actions: {
            if self.gateway.profile.access == .admin, !self.gateway.settings.canEdit {
                Text("The Gateway hasn't granted Full Management to this device yet.")
                    .foregroundStyle(.orange)
                ApprovalInstructions(requestId: nil)
                    .frame(maxWidth: 420)
            }
            Button("Open Connection") { self.navigator.destination = .connection }
        }
    }
}

enum DevicesUI {
    /// "Operator · Full Management" / "Operator · read, write, approvals".
    static func accessLine(roles: [String], scopes: [String]) -> String {
        let role = (roles.isEmpty ? ["operator"] : roles).map(\.capitalized).joined(separator: " + ")
        guard !scopes.isEmpty else { return role }
        if scopes.contains(GatewayConnection.adminScope) { return "\(role) · Full Management" }
        let names = scopes.map { $0.hasPrefix("operator.") ? String($0.dropFirst("operator.".count)) : $0 }
        return "\(role) · \(names.joined(separator: ", "))"
    }

    static func approveMessage(_ request: PendingDeviceRequest) -> String {
        var lines = [
            "Fingerprint: \(DeviceFingerprint.format(request.deviceId))",
            "Access: \(Self.accessLine(roles: request.roles, scopes: request.scopes))",
        ]
        if let ip = request.remoteIp { lines.append("From: \(ip)") }
        if request.requestsNodeRole { lines.append("It will be able to run commands for your agents.") }
        lines.append("Only approve devices you recognize.")
        return lines.joined(separator: "\n")
    }

    static func tokenLine(_ token: DeviceTokenSummary) -> String {
        if let revokedAt = token.revokedAt { return "Revoked \(revokedAt.formatted(date: .abbreviated, time: .omitted))" }
        if let used = token.lastUsedAt { return "Last used \(used.formatted(date: .abbreviated, time: .shortened))" }
        if let created = token.rotatedAt ?? token.createdAt { return "Issued \(created.formatted(date: .abbreviated, time: .omitted))" }
        return "Active"
    }
}

// MARK: Nodes

/// Gateway Settings → Nodes: devices that run commands for agents (`node.list`), with rename
/// (`node.rename`) and remove (`node.pair.remove`) for Full Management.
struct NodesPage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var removing: GatewayNode?
    @State private var renaming: GatewayNode?
    @State private var renameText = ""

    private var model: DeviceManagementModel { self.gateway.devices }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if !connected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see its nodes."))
            } else if !model.nodesSupported {
                ContentUnavailableView("Nodes Aren't Available", systemImage: "cpu",
                                       description: Text("This Gateway doesn't list nodes. Update OpenClaw to see them here."))
            } else {
                self.list(model)
            }
        }
        .navigationTitle("Nodes")
        .toolbar {
            if connected, model.nodesSupported {
                ToolbarItem {
                    Button { Task { await model.loadNodes() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.nodesLoadState.isRunning)
                        .help("Refresh")
                }
            }
        }
        .task(id: connected) {
            if connected { await model.loadNodes() }
        }
        .confirmationDialog(self.removing.map { "Remove \($0.title)?" } ?? "", isPresented: Binding(
            get: { self.removing != nil }, set: { if !$0 { self.removing = nil } }
        ), titleVisibility: .visible, presenting: self.removing) { node in
            Button("Remove", role: .destructive) { Task { await model.removeNode(node) } }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text(model.isSelf(node) ? DeviceManagementModel.selfRemoveWarning
                : "Agents can no longer run commands on \(node.title), and it's disconnected. It has to pair again to come back.")
        }
        .alert("Rename Node", isPresented: Binding(
            get: { self.renaming != nil }, set: { if !$0 { self.renaming = nil } }
        ), presenting: self.renaming) { node in
            TextField("Name", text: self.$renameText)
            Button("Save") {
                let name = self.renameText
                Task { await model.renameNode(node, to: name) }
            }
            .disabled(self.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .bottom) { DeviceNotice(model: model) }
    }

    private func list(_ model: DeviceManagementModel) -> some View {
        List {
            if let error = model.nodesLoadState.error, model.nodesLoaded {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    Button("Try Again") { Task { await model.loadNodes() } }
                }
            }
            if !model.nodes.isEmpty {
                Section {
                    ForEach(model.nodes) { node in
                        NodeRow(node: node, model: model,
                                rename: {
                                    self.renameText = node.displayName ?? ""
                                    self.renaming = node
                                },
                                remove: { self.removing = node })
                    }
                } footer: {
                    if model.canRemoveNodes || model.canRenameNodes {
                        Text("Approve new nodes on the Devices page.")
                    } else {
                        Text("Renaming and removing nodes needs Full Management.")
                    }
                }
            }
        }
        #if os(iOS)
        .refreshable { await model.loadNodes() }
        #endif
        .overlay {
            if model.nodes.isEmpty {
                if !model.nodesLoaded {
                    ProgressView()
                } else if model.nodesLoadState.error == nil {
                    ContentUnavailableView("No Nodes", systemImage: "cpu",
                                           description: Text("Macs, phones and servers that run commands for your agents show up here once they pair."))
                }
            }
        }
    }
}

private struct NodeRow: View {
    let node: GatewayNode
    let model: DeviceManagementModel
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        let operation = self.model.operation(for: self.node)
        let canAct = self.model.canRenameNodes || self.model.canRemoveNodes
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(self.node.connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(self.node.connected ? "Connected" : "Not connected")
                Text(self.node.title).font(.headline).lineLimit(1)
                if self.node.active { DeviceTag(text: "Active", color: .green) }
                if self.node.gatewayLocal { DeviceTag(text: "Gateway Host", color: .blue) }
                if let approval = self.node.approvalLabel { DeviceTag(text: approval, color: .orange) }
                Spacer(minLength: 8)
                if operation.isRunning { ProgressView().controlSize(.small) }
                if canAct {
                    Menu {
                        if self.model.canRenameNodes { Button("Rename…", systemImage: "pencil", action: self.rename) }
                        if self.model.canRemoveNodes {
                            Button("Remove…", systemImage: "trash", role: .destructive, action: self.remove)
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(operation.isRunning)
                    .accessibilityLabel("Actions for \(self.node.title)")
                }
            }
            if !self.node.subtitle.isEmpty {
                Text(self.node.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            FingerprintText(deviceId: self.node.nodeId)
            if !self.node.commands.isEmpty || !self.node.caps.isEmpty {
                Text(Self.capabilityLine(self.node)).font(.caption).foregroundStyle(.secondary)
            }
            if let lastSeen = self.node.lastSeenAt, !self.node.connected {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Last seen \(DeviceFingerprint.ago(lastSeen, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let error = operation.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Node ID", systemImage: "doc.on.doc") { Clipboard.copy(self.node.nodeId) }
            if self.model.canRenameNodes { Button("Rename…", systemImage: "pencil", action: self.rename) }
            if self.model.canRemoveNodes { Button("Remove…", systemImage: "trash", role: .destructive, action: self.remove) }
        }
    }

    /// "12 commands · camera, screen".
    static func capabilityLine(_ node: GatewayNode) -> String {
        var parts: [String] = []
        if !node.commands.isEmpty { parts.append("\(node.commands.count) command\(node.commands.count == 1 ? "" : "s")") }
        if !node.caps.isEmpty { parts.append(node.caps.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
