import PincerKit
import SwiftUI

// Gateway Settings → Skills: discovered skills by state (Ready, Needs Setup, Blocked, Disabled),
// each skill's detail and config, and ClawHub search and installs (`skills.*`). Browsing needs
// `operator.read`; installs, updates and config need Full Management, so without it the controls
// are disabled with one notice.

// MARK: Skills page

struct SkillsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var filter = ""
    /// Empty: the Gateway's default agent.
    @State private var agentId = ""

    private var model: SkillsModel { self.gateway.skills }
    private var selectedAgent: String { self.agentId.isEmpty ? self.gateway.defaultAgentId : self.agentId }
    /// What `skills.status` gets: nil (the Gateway default) until an agent id is known.
    private var requestAgent: String? { self.selectedAgent.isEmpty ? nil : self.selectedAgent }

    private struct LoadKey: Hashable {
        let connected: Bool
        let agentId: String?
    }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        let agents = self.gateway.agents.filter { !$0.isSystem }
        Form {
            Section {
                if agents.count > 1 {
                    Picker(L("Agent"), selection: Binding(
                        get: { self.selectedAgent },
                        set: { if $0 != self.selectedAgent { self.agentId = $0 } }
                    )) {
                        ForEach(agents) { agent in Text(agent.title).tag(agent.id) }
                    }
                }
                TextField(L("Filter skills"), text: self.$filter)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.skills.isEmpty)
                if model.supportsSearch {
                    NavigationLink(value: SettingsRoute.clawHub) {
                        Label(L("Browse ClawHub"), systemImage: "magnifyingglass")
                    }
                    .disabled(!connected)
                }
                SkillsReadOnlyNotice(model: model)
                SkillsMessages(model: model)
            } footer: {
                if let dir = model.report?.workspaceDir {
                    Text(dir).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            self.content(model, connected: connected)
        }
        .formStyle(.grouped)
        .navigationTitle(L("Skills"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Refresh"), systemImage: "arrow.clockwise") {
                    Task { await model.load(agentId: self.requestAgent) }
                }
                .disabled(!connected || model.isLoading)
            }
        }
        .onAppear { model.clearMessages() }
        .task(id: LoadKey(connected: connected, agentId: self.requestAgent)) {
            guard connected else { return }
            await model.loadIfNeeded(agentId: self.requestAgent)
        }
    }

    @ViewBuilder private func content(_ model: SkillsModel, connected: Bool) -> some View {
        if !connected {
            Section { Text("Connect to the Gateway to see skills.", bundle: .module).foregroundStyle(.secondary) }
        } else if model.report == nil, let error = model.loadError {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    Button(L("Retry")) { Task { await model.load(agentId: self.requestAgent) } }
                }
            }
        } else if model.report == nil {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if model.skills.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("No skills found", bundle: .module).font(.callout.weight(.medium))
                    Text(model.supportsSearch ? L("Browse ClawHub to find skills to install.") : L("Add skills to the agent's workspace on the Gateway host."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            let sections = model.sections(filter: self.filter)
            if sections.isEmpty {
                Section { Text("No skills match “\(self.filter)”.", bundle: .module).foregroundStyle(.secondary) }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.skills) { skill in
                        NavigationLink(value: SettingsRoute.skill(skill.skillKey)) {
                            SkillRow(skill: skill)
                        }
                    }
                } header: {
                    Text("\(section.state.title) (\(section.skills.count))")
                }
            }
        }
    }
}

/// "You can view skills. Turn on Full Management…" with Open Connection.
struct SkillsReadOnlyNotice: View {
    let model: SkillsModel
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        if !self.model.hasAdmin, self.model.supportsInstall || self.model.supportsUpdate {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label(L("Managing skills needs Full Management"), systemImage: "lock.shield")
                    .font(.callout.weight(.medium))
                Text(Skills.needsAdminMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("Open Connection")) { self.navigator.destination = .connection }
            }
        }
    }
}

/// The last install/update/config result: "Installed weather", or the Gateway's error.
private struct SkillsMessages: View {
    let model: SkillsModel

    var body: some View {
        if let error = self.model.actionError {
            Label(error, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if let message = self.model.lastMessage {
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
        SkillTrustWarnings(warnings: self.model.lastWarnings)
    }
}

/// ClawHub trust warnings from an install or update (`warning` / `details.warnings`).
private struct SkillTrustWarnings: View {
    let warnings: [String]

    var body: some View {
        ForEach(self.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }
}

struct SkillRow: View {
    let skill: SkillStatusEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            SkillIcon(emoji: self.skill.emoji)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(self.skill.name).font(.body.weight(.medium))
                    SkillBadge(text: self.skill.sourceKind.label)
                }
                if !self.skill.description.isEmpty {
                    Text(self.skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let reason = self.skill.primaryReason {
                    Text(reason).font(.caption).foregroundStyle(self.skill.state == .disabled ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SkillIcon: View {
    let emoji: String?

    var body: some View {
        Group {
            if let emoji { Text(emoji) } else { Image(systemName: "wand.and.stars").foregroundStyle(.tint) }
        }
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}

/// A small capsule label ("Bundled", "ClawHub", "Installed").
struct SkillBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(self.text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.hairline)
            .foregroundStyle(self.tint)
            .background(self.tint.opacity(0.12), in: Capsule())
    }
}

// MARK: Skill detail

/// One skill (`SettingsRoute.skill`): state and reasons, requirements, enable/disable, API key,
/// installers and ClawHub update.
struct SkillDetailPage: View {
    let skillKey: String
    @Environment(GatewayStore.self) private var gateway
    @State private var apiKey = ""
    @State private var envName = ""
    @State private var envValue = ""
    @State private var installer: SkillInstallOption?
    @State private var confirmUpdate = false
    @State private var confirmForce = false

    private var model: SkillsModel { self.gateway.skills }

    var body: some View {
        Group {
            if let skill = self.model.skill(key: self.skillKey) {
                self.form(skill)
            } else if !self.gateway.state.isConnected {
                ContentUnavailableView(L("Not Connected"), systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the Gateway to see skills.", bundle: .module))
            } else if self.model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(L("Skill Not Found"), systemImage: "wand.and.stars",
                                       description: Text("“\(self.skillKey)” isn't a skill on this Gateway anymore.", bundle: .module))
            }
        }
        .navigationTitle(self.model.skill(key: self.skillKey)?.name ?? self.skillKey)
        .task(id: self.gateway.state.isConnected) {
            guard self.gateway.state.isConnected, self.model.report == nil else { return }
            let fallback = self.gateway.defaultAgentId
            await self.model.loadIfNeeded(agentId: self.model.agentId ?? (fallback.isEmpty ? nil : fallback))
        }
        .onAppear { self.model.clearMessages() }
    }

    private var canChange: Bool { self.model.canUpdate && self.gateway.state.isConnected && !self.model.busy.contains(self.skillKey) }

    @ViewBuilder private func form(_ skill: SkillStatusEntry) -> some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                    SkillIcon(emoji: skill.emoji).font(.title2)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(skill.name).font(.title3.weight(.semibold))
                        if !skill.description.isEmpty {
                            Text(skill.description).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                LabeledContent(L("State")) {
                    Text(skill.state.title).foregroundStyle(skill.state == .ready ? Color.green : Color.orange)
                }
                ForEach(skill.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                SkillsReadOnlyNotice(model: self.model)
                SkillsMessages(model: self.model)
            }
            Section(L("Details")) {
                LabeledContent(L("Source"), value: skill.sourceKind.label)
                if let version = skill.clawhub?.installedVersion {
                    LabeledContent(L("Version"), value: version)
                }
                if let owner = skill.clawhub?.ownerHandle {
                    LabeledContent(L("Publisher"), value: "@\(owner)")
                }
                if let path = skill.filePath ?? skill.baseDir {
                    LabeledContent(L("Path")) {
                        Text(path).font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                if let homepage = skill.homepage, let url = URL(string: homepage) {
                    Link(destination: url) { Label(L("Homepage"), systemImage: "safari") }
                }
            }
            let checks = skill.requirementChecks
            if !checks.isEmpty {
                Section(L("Requirements")) {
                    ForEach(checks) { check in
                        Label {
                            Text(check.label)
                        } icon: {
                            Image(systemName: check.satisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(check.satisfied ? .green : .red)
                        }
                        .accessibilityValue(check.satisfied ? L("Met") : L("Missing"))
                    }
                }
            }
            if self.model.supportsUpdate {
                self.settings(skill)
            }
            if self.model.supportsInstall, !skill.install.isEmpty {
                Section {
                    ForEach(skill.install) { option in
                        Button {
                            self.installer = option
                        } label: {
                            Label(option.label, systemImage: "shippingbox")
                        }
                        .disabled(!self.model.canInstall || !self.gateway.state.isConnected || self.model.busy.contains(skill.skillKey))
                    }
                } header: {
                    Text("Installers", bundle: .module)
                } footer: {
                    Text("Installers run on the Gateway host to add what the skill needs.", bundle: .module)
                }
            }
            if skill.isClawHubTracked, self.model.supportsUpdate {
                Section {
                    Button(L("Update from ClawHub…"), systemImage: "arrow.down.circle") { self.confirmUpdate = true }
                        .disabled(!self.canChange)
                } footer: {
                    Text("Replaces the installed copy with ClawHub's latest version.", bundle: .module)
                }
            }
            if self.model.busy.contains(skill.skillKey) {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(self.installer.map(Skills.installerTitle) ?? "", isPresented: Binding(
            get: { self.installer != nil }, set: { if !$0 { self.installer = nil } }
        ), titleVisibility: .visible, presenting: self.installer) { option in
            Button(L("Run Installer")) {
                Task { _ = await self.model.runInstaller(skill: skill, option: option) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in
            Text("It runs with the Gateway's permissions.", bundle: .module)
        }
        .confirmationDialog(Skills.updateTitle(skill.name), isPresented: self.$confirmUpdate, titleVisibility: .visible) {
            Button(L("Update")) { Task { await self.update(skill, force: false) } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("This downloads the latest version from ClawHub onto the Gateway host.", bundle: .module)
        }
        .confirmationDialog(Skills.forceReplaceMessage(skill.name), isPresented: self.$confirmForce, titleVisibility: .visible) {
            Button(L("Replace"), role: .destructive) { Task { await self.update(skill, force: true) } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder private func settings(_ skill: SkillStatusEntry) -> some View {
        Section {
            Toggle(L("Enabled"), isOn: Binding(
                get: { !skill.disabled },
                set: { enabled in
                    guard enabled == skill.disabled else { return }
                    Task { _ = await self.model.setEnabled(skill, enabled) }
                }
            ))
            .disabled(!self.canChange)
            if let env = skill.apiKeyEnv {
                LabeledContent(L("API Key (\(env))"), value: skill.apiKeyIsSet ? "Set" : "Not set")
                HStack {
                    APIKeyField(title: L("New API key"), prompt: L("Paste API key"), text: self.$apiKey) {
                        self.saveApiKey(skill)
                    }
                    Button(L("Save")) { self.saveApiKey(skill) }
                        .disabled(!self.canChange || self.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .disabled(!self.canChange)
            }
            let otherEnv = skill.requirements.env.filter { $0 != skill.apiKeyEnv }
            ForEach(otherEnv, id: \.self) { env in
                LabeledContent(env, value: skill.missing.env.contains(env) ? "Not set" : "Set")
            }
            if !otherEnv.isEmpty {
                HStack {
                    Picker(L("Variable"), selection: Binding(
                        get: { self.envName.isEmpty ? (otherEnv.first ?? "") : self.envName },
                        set: { if $0 != self.envName { self.envName = $0 } }
                    )) {
                        ForEach(otherEnv, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    SecureField(L("Value"), text: self.$envValue)
                    Button(L("Save")) {
                        let name = self.envName.isEmpty ? (otherEnv.first ?? "") : self.envName
                        let value = self.envValue
                        self.envValue = ""
                        Task { _ = await self.model.setEnv(skill, name: name, value: value) }
                    }
                    .disabled(!self.canChange || self.envValue.isEmpty)
                }
                .disabled(!self.canChange)
            }
        } header: {
            Text("Settings", bundle: .module)
        } footer: {
            Text("\(Skills.settingsScopeFooter) Secrets are write-only: Pincer shows whether they're set, never their values.", bundle: .module)
        }
    }

    private func saveApiKey(_ skill: SkillStatusEntry) {
        let key = self.apiKey
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty, self.canChange else { return }
        self.apiKey = ""
        Task { _ = await self.model.setApiKey(skill, key) }
    }

    private func update(_ skill: SkillStatusEntry, force: Bool) async {
        if case .forceRequired = await self.model.updateFromClawHub(skill, force: force) {
            self.confirmForce = true
        }
    }
}

// MARK: ClawHub

/// ClawHub search (`SettingsRoute.clawHub`): results with install state; each opens its detail
/// with Install.
struct ClawHubSearchPage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var query = ""
    @State private var selected: ClawHubSearchResult?

    private var model: SkillsModel { self.gateway.skills }

    var body: some View {
        let model = self.model
        Form {
            Section {
                TextField(L("Search ClawHub"), text: self.$query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search(self.query) } }
                SkillsReadOnlyNotice(model: model)
                SkillsMessages(model: model)
            } footer: {
                Text("Skills install into \(self.agentName)'s workspace on the Gateway host.", bundle: .module)
            }
            self.results(model)
        }
        .formStyle(.grouped)
        .navigationTitle(L("Browse ClawHub"))
        .onAppear { model.clearMessages() }
        // Debounced: runs once typing pauses, not on every keystroke.
        .task(id: self.query) {
            let query = self.query
            guard query.trimmingCharacters(in: .whitespaces) != (model.searchedQuery ?? "") else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await model.search(query)
        }
        .sheet(item: self.$selected) { result in
            ClawHubSkillSheet(result: result, agentName: self.agentName)
                .environment(self.gateway)
        }
    }

    private var agentName: String {
        let id = self.model.agentId ?? self.gateway.defaultAgentId
        return self.gateway.agents.first { $0.id == id }?.name ?? id
    }

    @ViewBuilder private func results(_ model: SkillsModel) -> some View {
        if model.isSearching, model.searchResults.isEmpty {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if let error = model.searchError {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    Button(L("Retry")) { Task { await model.search(self.query) } }
                }
            }
        } else if let searched = model.searchedQuery {
            if model.searchResults.isEmpty {
                Section { Text("No skills match “\(searched)”.", bundle: .module).foregroundStyle(.secondary) }
            } else {
                Section(L("Results")) {
                    ForEach(model.searchResults) { result in
                        Button {
                            self.selected = result
                        } label: {
                            ClawHubResultRow(result: result, state: model.installState(for: result))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            Section { Text("Search ClawHub for skills by name or topic.", bundle: .module).foregroundStyle(.secondary) }
        }
    }
}

private struct ClawHubResultRow: View {
    let result: ClawHubSearchResult
    let state: ClawHubInstallState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(self.result.displayName).font(.body.weight(.medium))
                    if let label = self.state.label {
                        SkillBadge(text: label, tint: self.state == .notInstalled ? .secondary : (self.isUpdate ? .orange : .green))
                    }
                }
                if let summary = self.result.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(self.byline).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var isUpdate: Bool {
        if case .updateAvailable = self.state { return true }
        return false
    }

    private var byline: String {
        var parts: [String] = []
        if let owner = self.result.ownerHandle { parts.append("by @\(owner)") }
        if let version = self.result.version { parts.append("v\(version)") }
        if self.result.isUnscanned { parts.append("not scanned by ClawHub") }
        return parts.joined(separator: " · ")
    }
}

/// One ClawHub result: `skills.detail` (unless install-only) and, after confirming, Install (not
/// installed), Update (`skills.update`, which checks for local changes first) or Reinstall (a forced
/// `skills.install` that replaces the copy on the gateway).
private struct ClawHubSkillSheet: View {
    let result: ClawHubSearchResult
    let agentName: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ClawHubSkillDetail?
    @State private var detailError: String?
    @State private var confirmInstall = false
    @State private var confirmUpdate = false
    @State private var confirmReinstall = false
    @State private var confirmForce = false
    /// Whether the force_required retry is an update (else an install).
    @State private var forceIsUpdate = false
    @State private var installing = false
    @State private var outcome: SkillActionResult?

    private var model: SkillsModel { self.gateway.skills }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(self.result.displayName).font(.title3.weight(.semibold))
                        if let summary = self.detail?.summary ?? self.result.summary {
                            Text(summary).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if let owner = self.detail?.ownerName ?? self.result.ownerHandle.map({ "@\($0)" }) {
                        LabeledContent(L("Publisher"), value: owner + (self.detail?.isOfficial == true ? " (official)" : ""))
                    }
                    if let version = self.detail?.latestVersion ?? self.result.version {
                        LabeledContent(L("Latest Version"), value: version)
                    }
                    if let label = self.state.label {
                        LabeledContent(L("Status"), value: self.statusText ?? label)
                    }
                    if let os = self.detail?.os, !os.isEmpty {
                        LabeledContent(L("Platforms"), value: os.map(Skills.osName).joined(separator: ", "))
                    }
                    if self.result.isUnscanned {
                        Label(L("ClawHub hasn't scanned this skill's source."), systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                    }
                }
                if let changelog = self.detail?.changelog, !changelog.isEmpty {
                    Section(L("What's New")) { Text(changelog).textSelection(.enabled) }
                }
                if let error = self.detailError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                Section {
                    SkillsReadOnlyNotice(model: self.model)
                    if let outcome = self.outcome {
                        switch outcome {
                        case let .done(message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case let .failed(message), let .forceRequired(message):
                            Label(message, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                        }
                        SkillTrustWarnings(warnings: self.model.lastWarnings)
                    }
                    self.actionButton
                }
            }
            .formStyle(.grouped)
            .navigationTitle(self.result.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { self.dismiss() } }
            }
            .task {
                guard !self.result.installOnly, self.model.supportsDetail, self.detail == nil else { return }
                do { self.detail = try await self.model.detail(self.result.installRef) } catch {
                    self.detailError = AgentManagementError.classify(error).message
                }
            }
            .confirmationDialog(Skills.clawHubInstallTitle(self.result.displayName), isPresented: self.$confirmInstall,
                                titleVisibility: .visible) {
                Button(L("Install")) { Task { await self.install(force: false) } }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(Skills.installMessage(agentName: self.isDefaultAgent ? nil : self.agentName))
            }
            .confirmationDialog(Skills.updateTitle(self.result.displayName), isPresented: self.$confirmUpdate,
                                titleVisibility: .visible) {
                Button(L("Update")) { Task { await self.update(force: false) } }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text("This downloads the latest version from ClawHub onto the Gateway host.", bundle: .module)
            }
            .confirmationDialog(Skills.reinstallTitle(self.result.displayName), isPresented: self.$confirmReinstall,
                                titleVisibility: .visible) {
                Button(L("Reinstall"), role: .destructive) { Task { await self.install(force: true) } }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(Skills.reinstallMessage(self.result.displayName))
            }
            .confirmationDialog(Skills.forceReplaceMessage(self.result.displayName), isPresented: self.$confirmForce,
                                titleVisibility: .visible) {
                Button(L("Replace"), role: .destructive) {
                    Task {
                        if self.forceIsUpdate { await self.update(force: true) } else { await self.install(force: true) }
                    }
                }
                Button(L("Cancel"), role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private var isDefaultAgent: Bool { (self.model.agentId ?? self.gateway.defaultAgentId) == self.gateway.defaultAgentId }

    private var state: ClawHubInstallState { self.model.installState(for: self.result) }

    private var statusText: String? {
        switch self.state {
        case .notInstalled: nil
        case let .installed(version): version.map { "Installed (\($0))" } ?? "Installed"
        case let .updateAvailable(installed, latest): "Update available (\(installed) → \(latest))"
        }
    }

    private var installedSkill: SkillStatusEntry? { self.model.installedSkill(for: self.result) }

    private var isUpdate: Bool {
        if case .updateAvailable = self.state { return true }
        return false
    }

    private var isBusy: Bool {
        self.installing || self.installedSkill.map { self.model.busy.contains($0.skillKey) } == true
    }

    /// Install… when not installed, Update… when ClawHub has a newer version, else Reinstall….
    @ViewBuilder private var actionButton: some View {
        let connected = self.gateway.state.isConnected
        if self.isUpdate, self.installedSkill != nil, self.model.supportsUpdate {
            self.button("Update…", symbol: "arrow.down.circle") { self.confirmUpdate = true }
                .disabled(!self.model.canUpdate || !connected || self.isBusy)
        } else if self.model.supportsInstall {
            let installed = self.state != .notInstalled
            self.button(installed ? "Reinstall…" : "Install…", symbol: installed ? "arrow.clockwise.circle" : "arrow.down.circle") {
                if installed { self.confirmReinstall = true } else { self.confirmInstall = true }
            }
            .disabled(!self.model.canInstall || !connected || self.isBusy)
        }
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                if self.isBusy { Spacer(); ProgressView().controlSize(.small) }
            }
        }
    }

    private func install(force: Bool) async {
        self.installing = true
        let outcome = await self.model.installFromClawHub(self.result, force: force)
        self.installing = false
        if case .forceRequired = outcome {
            self.forceIsUpdate = false
            self.confirmForce = true
        } else {
            self.outcome = outcome
        }
    }

    /// `skills.update` without `force` first, so the Gateway refuses if the copy changed locally.
    private func update(force: Bool) async {
        guard let skill = self.installedSkill else { return }
        self.installing = true
        let outcome = await self.model.updateFromClawHub(skill, force: force)
        self.installing = false
        if case .forceRequired = outcome {
            self.forceIsUpdate = true
            self.confirmForce = true
        } else {
            self.outcome = outcome
        }
    }
}
