import PincerKit
import SwiftUI

// MARK: Opening

/// Opens Gateway Settings for a gateway: its own window on macOS, a sheet on iOS.
struct GatewaySettingsOpener {
    var open: @MainActor (GatewayStore, SettingsDestination?) -> Void = { _, _ in }

    @MainActor
    func callAsFunction(_ gateway: GatewayStore, at destination: SettingsDestination? = nil) {
        self.open(gateway, destination)
    }
}

extension EnvironmentValues {
    @Entry var openGatewaySettings = GatewaySettingsOpener()
}

/// A request to show Gateway Settings in a sheet (iOS).
struct GatewaySettingsRequest: Identifiable {
    let id: UUID
}

// MARK: Window

/// Gateway Settings for one gateway. The gateway is looked up on every render because
/// editing its connection replaces the `GatewayStore`; the navigation survives that.
struct GatewaySettingsWindow: View {
    let gatewayId: UUID?
    /// iOS: closes the sheet.
    var close: (() -> Void)?
    @Environment(AppModel.self) private var app
    @State private var navigator = SettingsNavigator(destination: nil)

    var body: some View {
        if let gateway = self.app.gateways.first(where: { $0.id == self.gatewayId }) {
            GatewaySettingsRoot(close: self.close)
                .environment(gateway)
                .environment(self.navigator)
                .environment(\.closeGatewaySettings, GatewaySettingsCloser(close: self.close))
        } else {
            ContentUnavailableView("Gateway Removed", systemImage: "server.rack",
                                   description: Text("This Gateway is no longer in Pincer."))
                .toolbar {
                    if let close = self.close {
                        ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                    }
                }
        }
    }
}

private struct GatewaySettingsRoot: View {
    var close: (() -> Void)?
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var search = ""
    @State private var confirmClose = false
    @State private var toast: (outcome: ConfigApplyOutcome, id: UUID)?

    private var settings: GatewaySettingsModel { self.gateway.settings }

    var body: some View {
        @Bindable var navigator = self.navigator
        let settings = self.settings
        NavigationSplitView {
            SettingsSidebar(search: self.$search)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
                #endif
                .toolbar {
                    if self.close != nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                if settings.hasChanges { self.confirmClose = true } else { self.close?() }
                            }
                        }
                    }
                }
        } detail: {
            NavigationStack(path: $navigator.path) {
                self.page(for: self.navigator.destination)
                    .navigationDestination(for: SettingsRoute.self) { route in
                        switch route {
                        case let .object(path): ConfigObjectPage(path: path)
                        case let .list(path): StringListPage(path: path)
                        case let .plugin(id): PluginPage(pluginId: id)
                        case let .approval(id): ApprovalDetailPage(approvalId: id)
                        }
                    }
            }
            .id(self.navigator.destination)
        }
        #if os(macOS)
        .navigationSubtitle(self.gateway.profile.name)
        #endif
        .sheet(isPresented: $navigator.isReviewing) {
            ReviewChangesSheet()
                .environment(self.gateway)
                .environment(self.navigator)
        }
        .alert("Couldn't Save Settings", isPresented: Binding(
            get: { settings.saveState.error != nil && !self.navigator.isReviewing },
            set: { if !$0 { settings.clearSaveError() } }
        )) {
            Button("Review Changes") {
                self.navigator.isReviewing = true
            }
            Button("OK", role: .cancel) { settings.clearSaveError() }
        } message: {
            Text(settings.saveState.error ?? "")
        }
        .confirmationDialog("Save changes to \(self.gateway.profile.name)?", isPresented: self.$confirmClose,
                            titleVisibility: .visible) {
            Button("Save") {
                Task { if await settings.save() { self.close?() } }
            }
            .disabled(settings.saveBlocker != nil || !settings.canEdit)
            Button("Discard Changes", role: .destructive) {
                settings.discardChanges()
                self.close?()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have \(settings.changeCount) unsaved change\(settings.changeCount == 1 ? "" : "s").")
        }
        #if os(iOS)
        .interactiveDismissDisabled(settings.hasChanges)
        #endif
        .overlay(alignment: .bottom) { self.toastView }
        .onChange(of: settings.lastSave?.id) { self.showToast() }
        .onAppear(perform: self.takeRequest)
        .onChange(of: settings.requestedDestination) { self.takeRequest() }
        .task(id: LoadKey(settings: ObjectIdentifier(settings), connected: self.gateway.state.isConnected)) {
            if self.gateway.state.isConnected { await settings.load() }
        }
    }

    private struct LoadKey: Hashable {
        let settings: ObjectIdentifier
        let connected: Bool
    }

    @ViewBuilder private func page(for destination: SettingsDestination?) -> some View {
        switch destination {
        case .connection: ConnectionPage()
        case .overview: OverviewPage()
        case .approvals: ApprovalHistoryPage()
        case .logs: GatewayLogsPage()
        case let .page(id):
            if let page = SettingsCatalog.page(id) { CuratedPage(page: page) }
        case .plugins: PluginsPage()
        case .allSettings: AllSettingsPage()
        case .raw: RawConfigPage()
        case nil:
            ContentUnavailableView("Gateway Settings", systemImage: "gearshape.2",
                                   description: Text("Choose a category."))
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast = self.toast {
            SaveOutcomeLabel(outcome: toast.outcome)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule())
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation { self.toast = nil } }
        }
    }

    private func showToast() {
        guard let last = self.settings.lastSave else { return }
        withAnimation { self.toast = last }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.toast?.id == last.id { withAnimation { self.toast = nil } }
        }
    }

    private func takeRequest() {
        if let requested = self.settings.requestedDestination {
            self.settings.requestedDestination = nil
            self.navigator.destination = requested
        } else if self.navigator.destination == nil {
            #if os(macOS)
            self.navigator.destination = .overview
            #endif
        }
    }
}

// MARK: Sidebar

private struct SettingsSidebar: View {
    @Binding var search: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = self.navigator
        let settings = self.gateway.settings
        List(selection: $navigator.destination) {
            if self.search.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    self.row("Connection", symbol: "network", .connection)
                    self.row("Overview", symbol: "info.circle", .overview)
                    self.row("Approval History", symbol: "checkmark.shield", .approvals)
                    self.row("Gateway Logs", symbol: "doc.text.magnifyingglass", .logs)
                }
                if settings.hasLoaded {
                    Section("Settings") {
                        ForEach(SettingsCatalog.pages.filter { settings.shows($0) }) { page in
                            self.row(page.title, symbol: page.symbol, .page(page.id),
                                     badge: page.roots.reduce(0) { $0 + settings.changeCount(under: [$1]) })
                        }
                        if settings.pluginsSupported {
                            self.row("Plugins", symbol: "puzzlepiece.extension", .plugins,
                                     badge: settings.changeCount(under: ["plugins"]),
                                     attention: settings.pluginsNeedingAttention > 0)
                        }
                    }
                    Section("Advanced") {
                        self.row("All Settings", symbol: "list.bullet.rectangle", .allSettings,
                                 badge: settings.changeCount)
                        self.row("Raw Config", symbol: "curlybraces", .raw)
                    }
                }
            } else {
                SearchResults(query: self.search)
            }
        }
        .navigationTitle("Gateway Settings")
        #if os(macOS)
        .searchable(text: self.$search, placement: .sidebar, prompt: "Search")
        #else
        .searchable(text: self.$search, prompt: "Search Settings")
        #endif
        .disabled(!settings.hasLoaded && !self.search.isEmpty)
    }

    private func row(_ title: String, symbol: String, _ destination: SettingsDestination, badge: Int = 0,
                     attention: Bool = false) -> some View {
        Label {
            HStack {
                Text(title)
                if attention {
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .badge(badge)
        .tag(destination)
    }
}

private struct SearchResults: View {
    let query: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        let results = self.results
        if results.isEmpty {
            Text("No settings match “\(self.query)”.").foregroundStyle(.secondary)
        }
        ForEach(results) { field in
            Button {
                self.navigator.go(to: field.path)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                    Text(Self.breadcrumb(field.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var results: [ConfigField] {
        let terms = self.query.lowercased().split(separator: " ").map(String.init)
        return Array(self.gateway.settings.searchIndex.filter { field in
            let haystack = ([field.label, field.help ?? ""] + field.path).joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }.prefix(60))
    }

    static func breadcrumb(_ path: [String]) -> String {
        path.dropLast().map { ConfigPath.humanized($0) }.joined(separator: " › ")
    }
}

// MARK: Save controls

extension View {
    /// Save and review controls for a page of Gateway settings.
    func settingsChrome() -> some View { self.modifier(SettingsChrome()) }
}

private struct SettingsChrome: ViewModifier {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirmDiscard = false

    func body(content: Content) -> some View {
        let settings = self.gateway.settings
        let count = settings.changeCount
        content
            .toolbar {
                #if os(macOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    if settings.hasLoaded, !settings.canEdit {
                        Button { self.navigator.destination = .connection } label: {
                            Label("Read Only", systemImage: "lock")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("This device can view settings but not change them. Open Connection to request Full Management.")
                    }
                    if settings.hasChanges {
                        Button("\(count) Unsaved") { self.navigator.isReviewing = true }
                            .help("Review unsaved changes")
                    }
                    Button("Save") { Task { await settings.save() } }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!settings.hasChanges || settings.isSaving || !settings.canEdit)
                        .help(settings.saveBlocker ?? "Save changes to the Gateway")
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    if settings.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await settings.save() } }
                            .disabled(!settings.hasChanges || !settings.canEdit)
                    }
                }
                if settings.hasChanges {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Discard", role: .destructive) { self.confirmDiscard = true }
                        Spacer()
                        Button("\(count) Change\(count == 1 ? "" : "s")") { self.navigator.isReviewing = true }
                    }
                }
                #endif
            }
            .confirmationDialog("Discard \(count) unsaved change\(count == 1 ? "" : "s")?",
                                isPresented: self.$confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { settings.discardChanges() }
            }
    }
}

// MARK: Review

/// Every unsaved change, with what it was, what it will be, and anything blocking the save.
struct ReviewChangesSheet: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    private var settings: GatewaySettingsModel { self.gateway.settings }

    var body: some View {
        let settings = self.settings
        NavigationStack {
            Form {
                self.errorSection
                self.conflictSection
                self.problemSection
                self.changeSections
            }
            .formStyle(.grouped)
            .navigationTitle("Unsaved Changes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if settings.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task { if await settings.save() { self.dismiss() } }
                        }
                        .disabled(!settings.hasChanges || settings.saveBlocker != nil || !settings.canEdit)
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Discard All", role: .destructive) { self.confirmDiscard = true }
                        .disabled(!settings.hasChanges)
                }
            }
            .confirmationDialog("Discard all unsaved changes?", isPresented: self.$confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) {
                    settings.discardChanges()
                    self.dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    @ViewBuilder private var errorSection: some View {
        let settings = self.settings
        if let error = settings.saveState.error {
            Section {
                Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                ForEach(settings.writeIssues) { issue in
                    Button { self.show(ConfigPath.parse(issue.path)) } label: {
                        IssueRow(issue: issue).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var conflictSection: some View {
        let settings = self.settings
        if !settings.conflicts.isEmpty {
            Section {
                ForEach(settings.conflicts) { conflict in
                    self.conflictRow(conflict)
                }
            } header: {
                Text("Changed on the Gateway")
            } footer: {
                Text("Someone changed these on the Gateway while you were editing. Choose which value to keep.")
            }
        }
    }

    @ViewBuilder private var problemSection: some View {
        let problems = self.problems
        if !problems.isEmpty {
            Section("Needs Fixing") {
                ForEach(problems, id: \.path) { problem in
                    Button { self.show(problem.path) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(self.label(problem.path))
                                Text(problem.message).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var changeSections: some View {
        let settings = self.settings
        let groups = Dictionary(grouping: settings.edits.changes) { $0.path.first ?? "" }
        if groups.isEmpty {
            Section { Text("No unsaved changes.").foregroundStyle(.secondary) }
        }
        ForEach(groups.keys.sorted(), id: \.self) { root in
            Section(ConfigPath.humanized(root)) {
                ForEach(groups[root] ?? []) { change in
                    self.changeRow(change)
                }
            }
        }
    }

    private struct Problem {
        let path: [String]
        let message: String
    }

    private var problems: [Problem] {
        var problems = self.settings.edits.inputErrors.map { Problem(path: ConfigPath.parse($0.key), message: $0.value) }
        for (id, message) in self.settings.validationProblems where self.settings.edits.inputErrors[id] == nil {
            problems.append(Problem(path: ConfigPath.parse(id), message: message))
        }
        return problems.sorted { ConfigPath.string($0.path) < ConfigPath.string($1.path) }
    }

    private func changeRow(_ change: ConfigEdits.Change) -> some View {
        let secret = self.isSecret(change.path)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.label(change.path))
                if change.path.count > 2 {
                    Text(SearchResults.breadcrumb(Array(change.path.dropFirst())))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(Self.summary(change.old, secret: secret, missing: "Not set"))
                        .strikethrough(change.old != nil)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(Self.summary(change.new, secret: secret, missing: "Removed"))
                }
                .font(.caption.monospaced())
                .lineLimit(2)
            }
            Spacer()
            Button("Show") { self.show(change.path) }
                .buttonStyle(.borderless)
            Button {
                self.settings.revert(change.path)
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Revert this change")
        }
        .contextMenu {
            Button("Show Setting") { self.show(change.path) }
            Button("Revert Change") { self.settings.revert(change.path) }
        }
    }

    private func conflictRow(_ conflict: ConfigEdits.Conflict) -> some View {
        let secret = self.isSecret(conflict.path)
        return VStack(alignment: .leading, spacing: 6) {
            Text(self.label(conflict.path))
            LabeledContent("Yours", value: Self.summary(conflict.mine, secret: secret, missing: "Removed"))
                .font(.caption.monospaced())
            LabeledContent("Gateway", value: Self.summary(conflict.theirs, secret: secret, missing: "Not set"))
                .font(.caption.monospaced())
            HStack {
                Button("Keep Mine") { self.settings.resolve(conflict, keepMine: true) }
                Button("Use Gateway's") { self.settings.resolve(conflict, keepMine: false) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func label(_ path: [String]) -> String {
        self.settings.field(at: path)?.label ?? ConfigPath.humanized(path.last ?? "")
    }

    private func isSecret(_ path: [String]) -> Bool {
        self.settings.field(at: path)?.kind == .secret
    }

    static func summary(_ value: JSONValue?, secret: Bool, missing: String) -> String {
        guard let value, !value.isNull else { return missing }
        if secret { return value.isRedacted ? "Saved secret" : "••••••" }
        switch value {
        case let .string(text): return text.isEmpty ? "\"\"" : text
        case let .array(items): return items.isEmpty ? "[]" : "\(items.count) item\(items.count == 1 ? "" : "s")"
        case let .object(fields): return fields.isEmpty ? "{}" : "\(fields.count) setting\(fields.count == 1 ? "" : "s")"
        default: return value.compactString()
        }
    }

    private func show(_ path: [String]) {
        self.dismiss()
        self.navigator.go(to: path)
    }
}
