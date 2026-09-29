import PincerKit
import SwiftUI

// The effective tools inspector: a chat's (or agent's) tool catalog and the policy that allows or
// denies each tool, before a run (`tools.catalog`, `tools.effective`). Read only.

/// The inspector's content. `model` is created outside `body` (by the button that opens it).
struct ToolsInspectorView: View {
    let model: ToolsInspectorModel
    /// "Session: Trip planning" or "Agent: Scout".
    let scopeTitle: String
    /// "Live policy from “Main”." when an agent's inspector used one of its chats.
    var scopeDetail: String?
    /// Where tool policy is edited, and the button's title.
    var policySettings: ToolPolicySettings?
    var openPolicySettings: ((SettingsDestination) -> Void)?
    /// Show only this MCP server's tools.
    var mcpServer: String?
    @State private var filter = ToolFilter.all
    @State private var search = ""
    @State private var clearedServer = false

    var body: some View {
        let model = self.model
        Form {
            Section {
                Text(self.scopeTitle).font(.headline)
                if let detail = self.scopeDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let server = self.mcpServer, !self.clearedServer {
                    HStack {
                        Label(L("Server: \(server)"), systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.callout)
                        Button(L("Show all tools"), systemImage: "xmark.circle.fill") { self.clearedServer = true }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                if let inspection = model.inspection {
                    Text(inspection.summary).foregroundStyle(.secondary)
                }
                if let note = model.effectiveNote {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.inspection?.notices ?? []) { notice in
                    Label(ToolsPolicy.noticeText(notice),
                          systemImage: notice.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(notice.isWarning ? Color.orange : Color.secondary)
                }
            }
            if let inspection = model.inspection {
                Section {
                    Picker(L("Show"), selection: self.$filter) {
                        ForEach(ToolFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(L("Filter tools"), text: self.$search)
                        .textFieldStyle(.roundedBorder)
                }
                let groups = self.serverGroups(inspection.filtered(self.filter, search: self.search))
                if groups.isEmpty {
                    Section {
                        Text(inspection.totalCount == 0 ? L("No tools.") : L("No tools match.")).foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section(group.label) {
                        ForEach(group.tools) { tool in ToolInspectorRow(tool: tool) }
                    }
                }
            } else if let error = model.error {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                        Button(L("Retry")) { Task { await model.load() } }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            Section {
                if let open = self.openPolicySettings, let target = self.policySettings {
                    Button(target.title, systemImage: target.symbol) { open(target.destination) }
                }
            } footer: {
                Text(ToolsPolicy.policyFootnote)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Refresh"), systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
        }
        .task { await model.loadIfNeeded() }
    }
}

extension ToolsInspectorView {
    private func serverGroups(_ groups: [InspectedToolGroup]) -> [InspectedToolGroup] {
        guard let server = self.mcpServer, !self.clearedServer else { return groups }
        return groups.compactMap { group in
            let tools = group.tools.filter { $0.source == .mcp && $0.sourceDetail == server }
            return tools.isEmpty ? nil : InspectedToolGroup(id: group.id, label: group.label, tools: tools)
        }
    }
}

private struct ToolInspectorRow: View {
    let tool: InspectedTool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            Image(systemName: ToolSymbols.symbol(for: self.tool.id))
                .frame(width: 20)
                .foregroundStyle(self.tool.isAllowed ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(self.tool.label).font(.body.weight(.medium))
                    SkillBadge(text: self.tool.sourceLabel)
                    if self.tool.risk == "high" { SkillBadge(text: "High risk", tint: .orange) }
                }
                if !self.tool.description.isEmpty {
                    Text(self.tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !self.tool.isAllowed {
                    ForEach(self.tool.reasons, id: \.self) { reason in
                        Text(reason).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            Text(self.tool.isAllowed ? L("Allowed") : L("Denied"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(self.tool.isAllowed ? Color.green : Color.red)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Chat entry point

/// The chat's "Tools & Policy…" sheet.
struct ChatToolsInspectorSheet: View {
    let model: ToolsInspectorModel
    let scopeTitle: String
    let gateway: GatewayStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openGatewaySettings) private var openGatewaySettings

    var body: some View {
        NavigationStack {
            ToolsInspectorView(model: self.model, scopeTitle: self.scopeTitle,
                               policySettings: ToolPolicySettings(self.gateway)) { destination in
                self.dismiss()
                self.openGatewaySettings(self.gateway, at: destination)
            }
            .navigationTitle(L("Tools & Policy"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { self.dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
        #endif
    }
}

// MARK: Agent entry point

/// One agent's tools (`SettingsRoute.agentTools`), from Agents & Models.
struct AgentToolsPage: View {
    let agentId: String
    /// Show only this MCP server's tools.
    var mcpServer: String?
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var model: ToolsInspectorModel?

    var body: some View {
        let agent = self.gateway.agents.first { $0.id == self.agentId }
        Group {
            if !self.gateway.state.isConnected {
                ContentUnavailableView(L("Not Connected"), systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the Gateway to see this agent's tools.", bundle: .module))
            } else if let model {
                ToolsInspectorView(model: model, scopeTitle: "Agent: \(agent?.title ?? self.agentId)",
                                   scopeDetail: model.effective == nil ? nil : self.liveChatTitle(model).map(ToolsPolicy.livePolicyNote),
                                   policySettings: ToolPolicySettings(self.gateway),
                                   openPolicySettings: { destination in self.navigator.destination = destination },
                                   mcpServer: self.mcpServer)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(L("Tools"))
        .task(id: self.gateway.state.isConnected) {
            guard self.gateway.state.isConnected else { return }
            if self.model == nil { self.model = self.gateway.toolsInspector(agentId: self.agentId) }
        }
    }

    private func liveChatTitle(_ model: ToolsInspectorModel) -> String? {
        guard let key = model.scope.sessionKey else { return nil }
        return self.gateway.sessions[key]?.title ?? key
    }
}

/// Where the inspector's settings button goes: the Tools & Skills page when this Gateway's config
/// has one, else Raw Config (so it never opens a dead page).
struct ToolPolicySettings {
    let title: String
    let symbol: String
    let destination: SettingsDestination

    @MainActor init(_ gateway: GatewayStore) {
        let settings = gateway.settings
        if settings.hasLoaded, let page = SettingsCatalog.pages.first(where: { $0.id == "tools" }), settings.shows(page) {
            self = ToolPolicySettings(title: "Tool Settings…", symbol: "wrench.and.screwdriver", destination: .page(page.id))
        } else {
            self = ToolPolicySettings(title: "Raw Config…", symbol: "curlybraces", destination: .raw)
        }
    }

    private init(title: String, symbol: String, destination: SettingsDestination) {
        self.title = title
        self.symbol = symbol
        self.destination = destination
    }
}
