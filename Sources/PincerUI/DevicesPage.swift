import PincerKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Gateway Settings → Devices: devices waiting to pair and devices paired with the Gateway
/// (`device.pair.*`). The Gateway authorizes device pairing actions; rename remains administrative.
/// `device.pair.requested` / `resolved` / `changed` events keep it current.
struct DevicesPage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var revoking: PairedDevice?
    @State private var renaming: PairedDevice?
    @State private var renameText = ""

    private var model: DeviceManagementModel { self.gateway.devices }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        let gatewayName = self.gateway.profile.name
        Group {
            if !connected {
                ContentUnavailableView(L("Not Connected"), systemImage: "bolt.horizontal.circle",
                                       description: Text(DeviceManagementModel.disconnectedMessage))
            } else if !model.supported {
                ContentUnavailableView(L("Devices Aren't Available"), systemImage: "laptopcomputer.and.iphone",
                                       description: Text(DeviceManagementModel.unsupportedMessage))
            } else if model.needsAccess {
                List { DeviceAccessNeeded() }
            } else {
                self.list(model)
            }
        }
        .navigationTitle(L("Devices"))
        .toolbar {
            if connected, model.supported, !model.needsAccess {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                        .disabled(model.loadState.isRunning)
                        .help(L("Refresh"))
                }
            }
        }
        .task(id: connected) {
            if connected { await model.load() }
        }
        .confirmationDialog(self.revoking.map { model.isSelf($0) ? "Revoke this device?" : "Revoke “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { self.revoking != nil }, set: { if !$0 { self.revoking = nil } }),
                            titleVisibility: .visible, presenting: self.revoking) { device in
            Button(model.isSelf(device) ? L("Revoke and Disconnect") : L("Revoke"), role: .destructive) {
                Task { await model.remove(device) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { device in
            Text(model.isSelf(device) ? DeviceManagementModel.selfRevokeWarning(gateway: gatewayName)
                : DeviceManagementModel.revokeMessage)
        }
        .alert(L("Rename Device"), isPresented: Binding(
            get: { self.renaming != nil }, set: { if !$0 { self.renaming = nil } }
        ), presenting: self.renaming) { device in
            TextField(L("Name"), text: self.$renameText)
            Button(L("Save")) {
                let label = self.renameText
                Task { await model.rename(device, to: label) }
            }
            .disabled(self.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in
            Text("The name is shown to every operator of this Gateway (up to \(DeviceManagementModel.maxLabelLength) characters).", bundle: .module)
        }
        .overlay(alignment: .bottom) { DeviceNotice(model: model) }
    }

    private func list(_ model: DeviceManagementModel) -> some View {
        List {
            if let reason = model.deviceReadOnlyReason {
                if reason == DeviceManagementModel.readOnlyMessage {
                    DeviceAccessNeeded(message: reason)
                } else {
                    Section { Text(reason).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error = model.loadState.error, model.hasLoaded {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    Button(L("Try Again")) { Task { await model.refresh() } }
                }
            }
            if model.hasLoaded || !model.pending.isEmpty || !model.paired.isEmpty {
                Section {
                    if model.pending.isEmpty {
                        DeviceEmptyRow(title: "No pending requests", detail: "New devices that try to connect show up here.")
                    }
                    ForEach(model.pending) { request in
                        PendingDeviceRow(request: request, model: model)
                    }
                } header: {
                    Text("Pending Requests", bundle: .module)
                } footer: {
                    if !model.pending.isEmpty {
                        Text("Only approve devices you recognize. Compare the fingerprint with the one the device shows while it waits.", bundle: .module)
                    }
                }
                Section(L("Paired Devices")) {
                    ForEach(model.paired) { device in
                        PairedDeviceRow(device: device, model: model,
                                        rename: {
                                            self.renameText = device.operatorLabel ?? device.displayName ?? ""
                                            self.renaming = device
                                        },
                                        revoke: { self.revoking = device })
                    }
                    if !model.paired.contains(where: { !model.isSelf($0) }) {
                        DeviceEmptyRow(title: "No other paired devices", detail: nil)
                    }
                }
            }
        }
        #if os(iOS)
        .refreshable { await model.refresh() }
        #endif
        .overlay {
            if !model.hasLoaded, model.pending.isEmpty, model.paired.isEmpty { ProgressView() }
        }
    }
}

// MARK: Rows

private struct PendingDeviceRow: View {
    let request: PendingDeviceRequest
    let model: DeviceManagementModel

    var body: some View {
        let operation = self.model.operation(for: self.request)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text(self.request.title).font(.headline).lineLimit(1)
                if self.request.isRepair { DeviceTag(text: "Scope upgrade", color: .orange) }
                if self.model.isSelf(self.request) { DeviceTag(text: DevicesUI.thisDeviceLabel, color: .accentColor) }
                Spacer(minLength: 8)
                #if os(macOS)
                self.buttons(busy: operation.isRunning)
                #endif
            }
            if !self.request.subtitle.isEmpty {
                Text(self.request.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let requestedAt = self.request.requestedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Requested \(DeviceFingerprint.ago(requestedAt, now: context.date))", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(requestedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            FingerprintText(deviceId: self.request.deviceId)
            AccessChips(roles: self.request.roles, scopes: self.request.scopes)
            if self.request.requestsNodeRole {
                Label(L("Asks to run commands for agents (node role)."), systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            DisclosureGroup(L("Details")) {
                DeviceDetails(deviceId: self.request.deviceId, clientId: self.request.clientId,
                              clientMode: self.request.clientMode, origin: self.request.browserOrigin,
                              scopes: self.request.scopes, requestId: self.request.requestId)
                if let ip = self.request.remoteIp { LabeledContent(L("Address"), value: ip).font(.caption) }
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
            .padding(.top, Theme.Spacing.xs)
            #endif
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contextMenu {
            Button(L("Copy Device ID"), systemImage: "doc.on.doc") { Clipboard.copy(self.request.deviceId) }
            Button(L("Copy Request ID"), systemImage: "number") { Clipboard.copy(self.request.requestId) }
        }
    }

    @ViewBuilder private func buttons(busy: Bool) -> some View {
        if busy { ProgressView().controlSize(.small) }
        if self.model.canRejectDevice {
            Button(L("Reject"), role: .destructive) { Task { await self.model.reject(self.request) } }
                .buttonStyle(.bordered)
                .disabled(busy)
                .accessibilityLabel(L("Reject \(self.request.title)"))
        }
        if self.model.canApproveDevice {
            Button(L("Approve")) { Task { await self.model.approve(self.request) } }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                .accessibilityLabel(L("Approve \(self.request.title)"))
        }
    }
}

private struct PairedDeviceRow: View {
    let device: PairedDevice
    let model: DeviceManagementModel
    let rename: () -> Void
    let revoke: () -> Void

    var body: some View {
        let operation = self.model.operation(for: self.device)
        let isSelf = self.model.isSelf(self.device)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text(self.device.title).font(.headline).lineLimit(1)
                if isSelf { DeviceTag(text: DevicesUI.thisDeviceLabel, color: .accentColor) }
                if self.device.isNode { DeviceTag(text: "Node", color: .purple) }
                Spacer(minLength: 8)
                if operation.isRunning { ProgressView().controlSize(.small) }
                self.menu(busy: operation.isRunning, isSelf: isSelf)
            }
            if !self.device.subtitle.isEmpty {
                Text(self.device.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            DevicePresence(connected: self.device.connected, lastSeen: self.device.lastActive)
            FingerprintText(deviceId: self.device.deviceId)
            AccessChips(roles: self.device.roles, scopes: self.device.effectiveScopes)
            DisclosureGroup(L("Details")) {
                DeviceDetails(deviceId: self.device.deviceId, clientId: self.device.clientId,
                              clientMode: self.device.clientMode, origin: nil,
                              scopes: self.device.effectiveScopes, requestId: nil)
                if let label = self.device.operatorLabel, let name = self.device.displayName, label != name {
                    LabeledContent(L("Device name"), value: name).font(.caption)
                }
                if let ip = self.device.remoteIp { LabeledContent(L("Address"), value: ip).font(.caption) }
                if let via = self.device.approvedViaLabel { LabeledContent(L("Approval"), value: via).font(.caption) }
                if let approvedAt = self.device.approvedAt {
                    LabeledContent(L("Approved"), value: approvedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
                ForEach(self.device.tokens, id: \.role) { token in
                    LabeledContent(L("\(token.role.capitalized) token"), value: DevicesUI.tokenLine(token)).font(.caption)
                }
            }
            .font(.caption)
            if let error = operation.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contextMenu { self.actions(isSelf: isSelf) }
    }

    @ViewBuilder private func actions(isSelf: Bool) -> some View {
        Button(L("Copy Device ID"), systemImage: "doc.on.doc") { Clipboard.copy(self.device.deviceId) }
        if self.model.canRename { Button(L("Rename…"), systemImage: "pencil", action: self.rename) }
        if self.model.canRemoveDevice {
            Divider()
            Button(isSelf ? L("Revoke This Device…") : L("Revoke…"), systemImage: "xmark.shield", role: .destructive, action: self.revoke)
        }
    }

    private func menu(busy: Bool, isSelf: Bool) -> some View {
        Menu {
            self.actions(isSelf: isSelf)
        } label: {
            Label(L("Actions"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .accessibilityLabel(L("Actions for \(self.device.title)"))
    }
}

// MARK: Pieces

private struct DeviceTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(self.text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.hairline)
            .background(self.color.opacity(0.15), in: Capsule())
            .foregroundStyle(self.color)
    }
}

private struct FingerprintText: View {
    let deviceId: String

    var body: some View {
        Label {
            Text(DeviceFingerprint.compact(self.deviceId))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
        } icon: {
            Image(systemName: "touchid").font(.caption)
        }
        .foregroundStyle(.secondary)
        .help(L("Fingerprint (SHA-256 of the device's public key): \(self.deviceId)"))
        .accessibilityLabel(L("Fingerprint \(DeviceFingerprint.compact(self.deviceId))"))
    }
}

/// "Connected" with a green dot, or "Last seen 3 hr ago".
private struct DevicePresence: View {
    let connected: Bool
    let lastSeen: Date?

    var body: some View {
        if self.connected {
            Label {
                Text("Connected", bundle: .module)
            } icon: {
                Circle().fill(Color.green).frame(width: 7, height: 7)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let lastSeen = self.lastSeen {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("Last seen \(DeviceFingerprint.ago(lastSeen, now: context.date))", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(lastSeen.formatted(date: .abbreviated, time: .shortened))
            }
        } else {
            Text("Not connected", bundle: .module).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Role and scope chips, with full scope names.
private struct AccessChips: View {
    let roles: [String]
    let scopes: [String]

    var body: some View {
        let roles = self.roles.isEmpty ? ["operator"] : self.roles
        ChipFlow(spacing: 4) {
            ForEach(roles, id: \.self) { role in
                DeviceTag(text: role, color: role == "node" ? .purple : .blue)
            }
            ForEach(self.scopes, id: \.self) { scope in
                Text(scope)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, Theme.Spacing.hairline)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(scope == GatewayConnection.adminScope ? Color.orange : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wraps chips onto new lines.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = self.rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + self.spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in self.rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + self.spacing
            }
            y += row.height + self.spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + self.spacing + size.width
            if extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row(indices: [index], width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width = extra
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

private struct DeviceEmptyRow: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(self.title).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, Theme.Spacing.xxs)
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
        LabeledContent(L("Device ID")) {
            Text(self.deviceId).font(.caption.monospaced()).textSelection(.enabled)
        }
        .font(.caption)
        if let clientId { LabeledContent(L("Client"), value: [clientId, self.clientMode].compactMap(\.self).joined(separator: " · ")).font(.caption) }
        if let origin { LabeledContent(L("Origin"), value: origin).font(.caption) }
        if !self.scopes.isEmpty {
            LabeledContent(L("Scopes")) {
                Text(self.scopes.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
            }
            .font(.caption)
        }
        if let requestId {
            LabeledContent(L("Request ID")) { Text(requestId).font(.caption.monospaced()).textSelection(.enabled) }
                .font(.caption)
        }
    }
}

/// The page's one-off message ("already handled"), like Pairing Requests'.
private struct DeviceNotice: View {
    let model: DeviceManagementModel

    var body: some View {
        if let notice = self.model.notice {
            SettingsNoticeBanner(id: notice.id, text: notice.text, severity: notice.severity,
                                 announces: true, dismiss: {
                guard self.model.notice?.id == notice.id else { return }
                withAnimation { self.model.clearNotice() }
            }) {
                Text(notice.text).font(.callout).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.lg)
            .glassSurface(in: Capsule())
            .padding(.horizontal)
            .padding(.bottom, Theme.Spacing.section)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onTapGesture {
                guard self.model.notice?.id == notice.id else { return }
                withAnimation { self.model.clearNotice() }
            }
        }
    }
}

/// Managing devices needs Full Management (`operator.admin`, which covers `operator.pairing`).
private struct DeviceAccessNeeded: View {
    var message = DeviceManagementModel.needsAccessMessage
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label(DeviceManagementModel.needsAccessTitle, systemImage: "lock.shield")
                    .font(.callout.weight(.medium))
                Text(self.message).font(.caption).foregroundStyle(.secondary)
                if self.gateway.profile.access == .admin, !self.gateway.settings.canEdit {
                    Text("The Gateway hasn't granted Full Management to this device yet.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    ApprovalInstructions(requestId: nil)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                Button(L("Open Connection")) { self.navigator.destination = .connection }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }
}

enum DevicesUI {
    /// "This Mac", "This iPhone" or "This iPad".
    @MainActor static let thisDeviceLabel: String = {
        #if os(macOS)
        "This Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #endif
    }()

    static func tokenLine(_ token: DeviceTokenSummary) -> String {
        if let revokedAt = token.revokedAt { return "Revoked \(revokedAt.formatted(date: .abbreviated, time: .omitted))" }
        if let used = token.lastUsedAt { return "Last used \(used.formatted(date: .abbreviated, time: .shortened))" }
        if let created = token.rotatedAt ?? token.createdAt { return "Issued \(created.formatted(date: .abbreviated, time: .omitted))" }
        return "Active"
    }
}

// MARK: Nodes

/// Gateway Settings → Nodes: devices that run commands for agents (`node.list`), read-only except
/// rename (`node.rename`) with Full Management. Pincer never registers as a node.
struct NodesPage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var renaming: GatewayNode?
    @State private var renameText = ""

    private var model: DeviceManagementModel { self.gateway.devices }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if !connected {
                ContentUnavailableView(L("Not Connected"), systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to a Gateway to see its nodes.", bundle: .module))
            } else if !model.nodesSupported {
                ContentUnavailableView(L("Nodes Aren't Available"), systemImage: "cpu",
                                       description: Text("This Gateway can't list nodes.", bundle: .module))
            } else {
                self.list(model)
            }
        }
        .navigationTitle(L("Nodes"))
        .toolbar {
            if connected, model.nodesSupported {
                ToolbarItem {
                    Button { Task { await model.loadNodes() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                        .disabled(model.nodesLoadState.isRunning)
                        .help(L("Refresh"))
                }
            }
        }
        .task(id: connected) {
            if connected { await model.loadNodes() }
        }
        .alert(L("Rename Node"), isPresented: Binding(
            get: { self.renaming != nil }, set: { if !$0 { self.renaming = nil } }
        ), presenting: self.renaming) { node in
            TextField(L("Name"), text: self.$renameText)
            Button(L("Save")) {
                let name = self.renameText
                Task { await model.renameNode(node, to: name) }
            }
            .disabled(self.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L("Cancel"), role: .cancel) {}
        }
        .overlay(alignment: .bottom) { DeviceNotice(model: model) }
    }

    private func list(_ model: DeviceManagementModel) -> some View {
        List {
            if let error = model.nodesLoadState.error, model.nodesLoaded {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    Button(L("Try Again")) { Task { await model.loadNodes() } }
                }
            }
            if !model.nodes.isEmpty {
                Section {
                    ForEach(model.nodes) { node in
                        NodeRow(node: node, model: model) {
                            self.renameText = node.displayName ?? ""
                            self.renaming = node
                        }
                    }
                } footer: {
                    if model.canRenameNodes {
                        Text("Approve new nodes on the Devices page.", bundle: .module)
                    } else {
                        Text("Renaming nodes needs Full Management.", bundle: .module)
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
                    ContentUnavailableView(L("No paired nodes"), systemImage: "cpu",
                                           description: Text("Nodes such as the OpenClaw Mac, iOS or Android apps show up here after they pair.", bundle: .module))
                }
            }
        }
    }
}

private struct NodeRow: View {
    let node: GatewayNode
    let model: DeviceManagementModel
    let rename: () -> Void

    var body: some View {
        let operation = self.model.operation(for: self.node)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text(self.node.title).font(.headline).lineLimit(1)
                if self.node.active { DeviceTag(text: "Active", color: .green) }
                if self.node.gatewayLocal { DeviceTag(text: "Gateway Host", color: .blue) }
                if let approval = self.node.approvalLabel { DeviceTag(text: approval, color: .orange) }
                Spacer(minLength: 8)
                if operation.isRunning { ProgressView().controlSize(.small) }
                if self.model.canRenameNodes {
                    Button(L("Rename…"), action: self.rename)
                        .buttonStyle(.borderless)
                        .disabled(operation.isRunning)
                        .accessibilityLabel(L("Rename \(self.node.title)"))
                }
            }
            if !self.node.subtitle.isEmpty {
                Text(self.node.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            DevicePresence(connected: self.node.connected, lastSeen: self.node.lastSeenAt)
            if !self.node.commands.isEmpty || !self.node.caps.isEmpty {
                Text(Self.capabilityLine(self.node)).font(.caption).foregroundStyle(.secondary)
                    .help(self.node.caps.joined(separator: ", "))
            }
            FingerprintText(deviceId: self.node.nodeId)
            if let error = operation.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contextMenu {
            Button(L("Copy Node ID"), systemImage: "doc.on.doc") { Clipboard.copy(self.node.nodeId) }
            if self.model.canRenameNodes { Button(L("Rename…"), systemImage: "pencil", action: self.rename) }
        }
    }

    /// "3 capabilities · 12 commands".
    static func capabilityLine(_ node: GatewayNode) -> String {
        var parts: [String] = []
        if !node.caps.isEmpty { parts.append("\(node.caps.count) capabilit\(node.caps.count == 1 ? "y" : "ies")") }
        if !node.commands.isEmpty { parts.append("\(node.commands.count) command\(node.commands.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
