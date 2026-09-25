import PincerKit
import SwiftUI

/// Shows a session's model and changes it. Only new messages use the new model; earlier replies
/// keep the model the Gateway recorded for them.
struct ModelPicker: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway

    private var catalog: [ModelChoice]? { self.gateway.modelCatalogs[self.row.agentId] }
    private var isLoading: Bool { self.gateway.loadingModelCatalogs.contains(self.row.agentId) }
    private var currentRef: String? { self.row.modelRef ?? self.gateway.defaultModelRef }
    private var followsDefault: Bool {
        // Older Gateways don't project `modelOverrideSource`; compare with the default instead.
        if self.row.raw["modelOverrideSource"] != nil { return self.row.modelOverrideSource == nil }
        return self.row.modelRef == nil || self.row.modelRef == self.gateway.defaultModelRef
    }

    var body: some View {
        Menu {
            self.content
        } label: {
            Label(self.currentRef.map(ModelRef.shortName) ?? "Model", systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(self.row.isModelSelectionLocked)
        .help(self.help)
        .task(id: self.row.agentId) { await self.gateway.loadModels(agentId: self.row.agentId) }
    }

    private var help: String {
        guard let ref = self.currentRef else { return "Choose the model for new messages" }
        if let active = self.row.activeModelRef, active != ref { return "Model: \(ref) (currently running \(active))" }
        return "Model: \(ref)"
    }

    @ViewBuilder private var content: some View {
        Button {
            Task { await self.gateway.setModel(self.row.key, to: nil) }
        } label: {
            let title = self.gateway.defaultModelRef.map { "Default (\(ModelRef.shortName($0)))" } ?? "Default"
            if self.followsDefault { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        Divider()
        if let catalog, !catalog.isEmpty {
            ForEach(Self.grouped(catalog), id: \.provider) { group in
                Section(group.provider) {
                    ForEach(group.models) { model in
                        Button {
                            Task { await self.gateway.setModel(self.row.key, to: model.ref) }
                        } label: {
                            if !self.followsDefault, model.ref == self.row.modelRef {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                        .disabled(!model.isAvailable || !model.manualSelectionAllowed)
                    }
                }
            }
        } else {
            Text(self.isLoading ? "Loading models…" : "No models available")
        }
        Divider()
        Button("Refresh Models", systemImage: "arrow.clockwise") {
            Task { await self.gateway.loadModels(agentId: self.row.agentId, refresh: true) }
        }
    }

    private static func grouped(_ models: [ModelChoice]) -> [(provider: String, models: [ModelChoice])] {
        var order: [String] = []
        var groups: [String: [ModelChoice]] = [:]
        for model in models {
            if groups[model.provider] == nil { order.append(model.provider) }
            groups[model.provider, default: []].append(model)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
