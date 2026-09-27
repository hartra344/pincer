import PincerKit
import SwiftUI

// The effective tools inspector: a chat's (or agent's) tool catalog and the policy that allows or
// denies each tool, before a run (`tools.catalog`, `tools.effective`). Read only.

/// The inspector's content. `model` is created outside `body` (by the button that opens it).
struct ToolsInspectorView: View {
    let model: ToolsInspectorModel
    /// "Session: Trip planning" or "Agent: Scout".
    let scopeTitle: String
    /// Opens where tool policy is edited.
    var openPolicySettings: (() -> Void)?
    @State private var filter = ToolFilter.all
    @State private var search = ""

    var body: some View {
        let model = self.model
        Form {
            Section {
                Text(self.scopeTitle).font(.headline)
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
                    Picker("Show", selection: self.$filter) {
                        ForEach(ToolFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Filter tools", text: self.$search)
                        .textFieldStyle(.roundedBorder)
                }
                let groups = inspection.filtered(self.filter, search: self.search)
                if groups.isEmpty {
                    Section {
                        Text(inspection.totalCount == 0 ? "No tools." : "No tools match.").foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section(group.label) {
                        ForEach(group.tools) { tool in ToolInspectorRow(tool: tool) }
                    }
                }
            } else if let error = model.error {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                        Button("Retry") { Task { await model.load() } }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            Section {
                if let open = self.openPolicySettings {
                    Button("Tool Settings…", systemImage: "wrench.and.screwdriver", action: open)
                }
            } footer: {
                Text(ToolsPolicy.policyFootnote)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
        }
        .task { await model.loadIfNeeded() }
    }
}

private struct ToolInspectorRow: View {
    let tool: InspectedTool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ToolSymbols.symbol(for: self.tool.id))
                .frame(width: 20)
                .foregroundStyle(self.tool.isAllowed ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
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
            Text(self.tool.isAllowed ? "Allowed" : "Denied")
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
            ToolsInspectorView(model: self.model, scopeTitle: self.scopeTitle) {
                self.dismiss()
                self.openGatewaySettings(self.gateway, at: .page("tools"))
            }
            .navigationTitle("Tools & Policy")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { self.dismiss() } }
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
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var model: ToolsInspectorModel?

    var body: some View {
        let agent = self.gateway.agents.first { $0.id == self.agentId }
        Group {
            if !self.gateway.state.isConnected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see this agent's tools."))
            } else if let model {
                ToolsInspectorView(model: model, scopeTitle: "Agent: \(agent?.title ?? self.agentId)") {
                    self.navigator.destination = .page("tools")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Tools")
        .task(id: self.gateway.state.isConnected) {
            guard self.gateway.state.isConnected else { return }
            if self.model == nil { self.model = self.gateway.toolsInspector(agentId: self.agentId) }
        }
    }
}
