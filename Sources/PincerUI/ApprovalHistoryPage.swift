import PincerKit
import SwiftUI

/// iOS: closes the Gateway Settings sheet, e.g. to show a chat.
struct GatewaySettingsCloser {
    var close: (() -> Void)?

    func callAsFunction() { self.close?() }
}

extension EnvironmentValues {
    @Entry var closeGatewaySettings = GatewaySettingsCloser()
}

// MARK: List

/// Gateway Settings → Approval History: the last 30 days of decisions on commands, plugins and
/// system changes, newest first (`approval.history`).
struct ApprovalHistoryPage: View {
    @Environment(GatewayStore.self) private var gateway

    private var model: ApprovalHistoryModel { self.gateway.approvalHistory }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if !model.supported {
                ContentUnavailableView("Approval History Isn't Available", systemImage: "clock.badge.xmark",
                                       description: Text("This gateway doesn't keep an approval history. Update OpenClaw to see past decisions."))
            } else {
                self.list(model, connected: connected)
            }
        }
        .navigationTitle("Approval History")
        .toolbar {
            if model.supported {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(!connected || model.loadState.isRunning)
                        .help("Refresh")
                }
            }
        }
        .task(id: connected) {
            // Coming back from a detail page (or reconnecting) keeps the pages already loaded.
            guard connected else { return }
            if model.hasLoaded, !model.items.isEmpty { await model.mergeLatest() } else { await model.load() }
        }
    }

    private func list(_ model: ApprovalHistoryModel, connected: Bool) -> some View {
        List {
            if let error = model.loadState.error, !model.items.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    Button("Try Again") { Task { await model.refresh() } }
                        .disabled(!connected)
                }
            }
            Section {
                ForEach(model.items) { record in
                    NavigationLink(value: SettingsRoute.approval(record.id)) {
                        ApprovalRow(record: record)
                    }
                }
                if model.hasMore {
                    self.loadMore(model, connected: connected)
                }
            } footer: {
                if !connected, !model.items.isEmpty {
                    Text("Not connected.")
                }
            }
        }
        #if os(iOS)
        .refreshable { if connected { await model.refresh() } }
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Kind", selection: Binding(
                get: { model.kindFilter },
                set: { filter in Task { await model.setKindFilter(filter) } }
            )) {
                ForEach(ApprovalHistoryModel.KindFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!connected)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .overlay { self.state(model, connected: connected) }
    }

    @ViewBuilder private func loadMore(_ model: ApprovalHistoryModel, connected: Bool) -> some View {
        HStack {
            Spacer()
            if model.loadMoreState.isRunning {
                ProgressView().controlSize(.small)
            } else if model.loadMoreState.error != nil {
                Text("Couldn't load more.").foregroundStyle(.secondary)
                Button("Try Again") { Task { await model.loadMore() } }
                    .disabled(!connected)
            } else {
                Button("Load More") { Task { await model.loadMore() } }
                    .disabled(!connected || model.loadState.isRunning)
            }
            Spacer()
        }
        .font(.callout)
        .help(model.loadMoreState.error ?? "")
    }

    @ViewBuilder private func state(_ model: ApprovalHistoryModel, connected: Bool) -> some View {
        if model.items.isEmpty {
            if !connected, !model.loadState.isRunning {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see its approval history."))
            } else if !model.hasLoaded || model.loadState.isRunning {
                ProgressView()
            } else if let error = model.loadState.error {
                ContentUnavailableView {
                    Label("Couldn't Load History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            } else if let filtered = model.kindFilter.emptyMessage {
                ContentUnavailableView("No Approval History", systemImage: "checkmark.shield",
                                       description: Text(filtered))
            } else {
                ContentUnavailableView("No Approval History", systemImage: "checkmark.shield",
                                       description: Text("Decisions on commands, plugins and system changes show up here for 30 days. Pending approvals appear in the chat."))
            }
        }
    }
}

// MARK: Row

private struct ApprovalRow: View {
    let record: ApprovalRecord
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        HStack(spacing: 10) {
            ApprovalKindIcon(kind: self.record.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.record.displayTitle)
                    .font(self.record.commandText != nil ? .body.monospaced() : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = ApprovalFormatting.requester(self.record, gateway: self.gateway) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                ApprovalStatusCapsule(record: self.record)
                if let resolved = self.record.resolvedAt {
                    Text(resolved.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ApprovalKindIcon: View {
    let kind: ApprovalRecord.Kind

    var body: some View {
        Image(systemName: self.symbol)
            .foregroundStyle(.secondary)
            .frame(width: 20)
            .accessibilityLabel(self.kind.label)
    }

    private var symbol: String {
        switch self.kind {
        case .exec: "terminal"
        case .plugin: "puzzlepiece.extension"
        case .systemAgent: "gearshape.2"
        case .other: "questionmark.circle"
        }
    }
}

private struct ApprovalStatusCapsule: View {
    let record: ApprovalRecord

    var body: some View {
        Text(self.record.statusLabel)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(self.color)
            .background(self.color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch self.record.tone {
        case .allowed: .green
        case .denied: .red
        case .neutral: .secondary
        }
    }
}

private enum ApprovalFormatting {
    /// "Claw · Japan trip": the agent that asked and its chat.
    @MainActor
    static func requester(_ record: ApprovalRecord, gateway: GatewayStore) -> String? {
        let parts = [record.agentId.map { gateway.agent($0).name }, self.chat(record, gateway: gateway)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    static func chat(_ record: ApprovalRecord, gateway: GatewayStore) -> String? {
        guard let key = record.sessionKey else { return nil }
        return gateway.sessions[key]?.title ?? key
    }

    static func date(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "—"
    }
}

// MARK: Detail

/// One approval: the row's data at once, then the full record from `approval.get`.
struct ApprovalDetailPage: View {
    let approvalId: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @Environment(\.closeGatewaySettings) private var closeSettings
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private var model: ApprovalHistoryModel { self.gateway.approvalHistory }

    var body: some View {
        let model = self.model
        Group {
            if let record = model.record(self.approvalId) {
                self.form(record, model: model)
            } else if model.detailState[self.approvalId]?.isRunning == true {
                ProgressView()
            } else if !self.gateway.state.isConnected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see this approval."))
            } else {
                ContentUnavailableView("Approval Not Found", systemImage: "checkmark.shield",
                                       description: Text(model.detailState[self.approvalId]?.error
                                           ?? "This approval is no longer on the Gateway."))
            }
        }
        .navigationTitle("Approval")
        .task(id: self.gateway.state.isConnected) {
            if self.gateway.state.isConnected { await model.loadDetail(self.approvalId) }
        }
    }

    private func form(_ record: ApprovalRecord, model: ApprovalHistoryModel) -> some View {
        Form {
            self.request(record)
            self.requester(record)
            Section("Decision") {
                LabeledContent("Outcome") { ApprovalStatusCapsule(record: record) }
                if let decision = record.decision { LabeledContent("Decision", value: decision.label) }
                if let reason = record.reason { LabeledContent("Reason", value: reason.explanation) }
                LabeledContent("Decided by", value: model.decidedBy(record))
            }
            Section("Times") {
                LabeledContent("Requested", value: ApprovalFormatting.date(record.createdAt))
                LabeledContent("Decided", value: ApprovalFormatting.date(record.resolvedAt))
                LabeledContent("Expires", value: ApprovalFormatting.date(record.expiresAt))
            }
            Section {
                LabeledContent("ID") {
                    Text(record.id).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Copy ID", systemImage: "doc.on.doc") { Clipboard.copy(record.id) }
            } footer: {
                if model.detailState[self.approvalId]?.isRunning == true {
                    ProgressView().controlSize(.small)
                } else if let error = model.detailState[self.approvalId]?.error {
                    Text("Couldn't load the full record: \(error)")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func request(_ record: ApprovalRecord) -> some View {
        Section("Request") {
            LabeledContent("Kind", value: record.kind.label)
            if let command = record.commandText ?? record.commandPreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy Command", systemImage: "doc.on.doc") { Clipboard.copy(command) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            if let title = record.title, record.commandText == nil {
                Text(title).font(.headline)
            }
            if let description = record.description {
                Text(description).textSelection(.enabled)
            }
            if let detail = record.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let warning = record.warningText {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let host = record.host { LabeledContent("Host", value: host) }
            if let node = record.nodeId { LabeledContent("Node", value: node) }
            if let plugin = record.pluginId { LabeledContent("Plugin", value: plugin) }
            if let tool = record.toolName { LabeledContent("Tool", value: tool) }
            if let severity = record.severity { LabeledContent("Severity", value: severity.capitalized) }
        }
    }

    @ViewBuilder private func requester(_ record: ApprovalRecord) -> some View {
        Section("Requested by") {
            LabeledContent("Agent", value: record.agentId.map { self.gateway.agent($0).name } ?? "Unknown")
            LabeledContent("Chat", value: ApprovalFormatting.chat(record, gateway: self.gateway) ?? "Unknown")
            if let key = record.sessionKey, self.gateway.sessions[key] != nil, self.canOpenChat {
                Button("Open Chat", systemImage: "bubble.left.and.text.bubble.right") { self.openChat(key) }
            }
        }
    }

    /// iOS: opening a chat closes the settings sheet, which would drop unsaved changes.
    private var canOpenChat: Bool {
        #if os(iOS)
        !self.gateway.settings.hasChanges
        #else
        true
        #endif
    }

    /// Shows the chat in the main window.
    private func openChat(_ key: String) {
        self.app.open(Notifier.Target(gatewayId: self.gateway.id, sessionKey: key))
        #if os(macOS)
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            self.openWindow(id: "main")
        }
        #else
        self.closeSettings()
        #endif
    }
}
