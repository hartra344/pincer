import PincerKit
import SwiftUI

/// Presents the selected gateway's setup wizard as a sheet. Attached once, in `RootView`.
struct SetupWizardPresenter: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        if let gateway = self.app.selectedGateway {
            content.modifier(SetupWizardSheet(gateway: gateway, setup: gateway.setup))
        } else {
            content
        }
    }
}

private struct SetupWizardSheet: ViewModifier {
    let gateway: GatewayStore
    @Bindable var setup: SetupWizardModel
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    /// iOS: a Gateway Settings page to open once the sheet is gone (one sheet at a time).
    @State private var pendingDestination: SettingsDestination?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: self.$setup.isPresented, onDismiss: self.dismissed) {
                SetupWizardView(setup: self.setup, openSettings: self.openSettings)
                    .environment(self.gateway)
            }
    }

    private func openSettings(_ destination: SettingsDestination) {
        #if os(macOS)
        self.openGatewaySettings(self.gateway, at: destination)
        #else
        self.pendingDestination = destination
        self.setup.close()
        #endif
    }

    private func dismissed() {
        self.setup.close()
        guard let destination = self.pendingDestination else { return }
        self.pendingDestination = nil
        self.openGatewaySettings(self.gateway, at: destination)
    }
}

// MARK: Wizard

struct SetupWizardView: View {
    let setup: SetupWizardModel
    let openSettings: (SettingsDestination) -> Void
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        Group {
            if self.setup.showsIntro {
                SetupIntroView(setup: self.setup)
            } else {
                self.steps
            }
        }
        #if os(macOS)
        .frame(width: 720, height: 520)
        #endif
        .task(id: self.gateway.state.isConnected) {
            guard self.gateway.state.isConnected else { return }
            await self.setup.load()
        }
    }

    private var steps: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            SetupStepList(setup: self.setup)
                .frame(width: 210)
            Divider()
            SetupStepDetail(setup: self.setup, openSettings: self.openSettings)
        }
        #else
        NavigationStack {
            VStack(spacing: 0) {
                SetupStepStrip(setup: self.setup)
                Divider()
                SetupStepDetail(setup: self.setup, openSettings: self.openSettings)
            }
            .navigationTitle("Set Up \(self.gateway.profile.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { self.setup.close() } }
            }
        }
        #endif
    }
}

private struct SetupIntroView: View {
    let setup: SetupWizardModel
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "checklist")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Set Up \(self.gateway.profile.name)")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Check the Gateway's health, channels, default agent and skills, then send a test message. Skip anything you like.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SetupStep.allCases) { step in
                    Label(step.title, systemImage: step.symbol)
                }
            }
            .padding(.vertical, 4)
            HStack(spacing: 12) {
                Button("Not Now") { self.setup.notNow() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Setup") { self.setup.startSetup() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Step list

private struct SetupStatusIcon: View {
    let status: SetupStepStatus

    var body: some View {
        Image(systemName: self.status.symbol)
            .foregroundStyle(Self.color(self.status))
            .accessibilityLabel(self.status.label)
    }

    static func color(_ status: SetupStepStatus) -> Color {
        switch status {
        case .done: .green
        case .needsAttention: .orange
        case .skipped, .notChecked: .secondary
        }
    }
}

#if os(macOS)
private struct SetupStepList: View {
    @Bindable var setup: SetupWizardModel
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set Up \(self.gateway.profile.name)")
                .font(.headline)
                .lineLimit(2)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 10)
            List(SetupStep.allCases, selection: Binding(get: { self.setup.currentStep },
                                                         set: { if let step = $0 { self.setup.currentStep = step } })) { step in
                let status = self.setup.status(of: step)
                HStack(spacing: 8) {
                    SetupStatusIcon(status: status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                        Text(status.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(step)
            }
            .listStyle(.sidebar)
            Text("\(self.setup.settledCount) of \(SetupStep.allCases.count) done or skipped")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }
}
#else
private struct SetupStepStrip: View {
    let setup: SetupWizardModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SetupStep.allCases) { step in
                    let status = self.setup.status(of: step)
                    Button { self.setup.currentStep = step } label: {
                        HStack(spacing: 4) {
                            SetupStatusIcon(status: status)
                            Text(step.title)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(step == self.setup.currentStep ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(step.title), \(status.label)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
#endif

// MARK: Step detail

private struct SetupStepDetail: View {
    let setup: SetupWizardModel
    let openSettings: (SettingsDestination) -> Void
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let step = self.setup.currentStep
        let status = self.setup.status(of: step)
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: step.symbol).font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.title3.bold())
                            HStack(spacing: 4) {
                                SetupStatusIcon(status: status)
                                Text(status.label).foregroundStyle(SetupStatusIcon.color(status))
                            }
                            .font(.callout)
                            if let detail = status.detail ?? self.setup.evaluated(step).detail {
                                Text(detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if self.setup.needsFullManagement(step) {
                        FullManagementBadge { self.openSettings(.connection) }
                    }
                }
                switch step {
                case .health: SetupHealthStep(openSettings: self.openSettings)
                case .channels: SetupChannelsStep(setup: self.setup, openSettings: self.openSettings)
                case .agent: SetupAgentStep(setup: self.setup, openSettings: self.openSettings)
                case .skills: SetupSkillsStep(setup: self.setup, openSettings: self.openSettings)
                case .testMessage: SetupTestMessageStep(setup: self.setup)
                }
            }
            .formStyle(.grouped)
            Divider()
            self.footer(step: step, status: status)
        }
    }

    private func footer(step: SetupStep, status: SetupStepStatus) -> some View {
        HStack {
            Button("Back") { self.setup.goBack() }
                .disabled(self.setup.previousStep == nil)
            if self.setup.loadState.isRunning {
                ProgressView().controlSize(.small).padding(.leading, 4)
            } else {
                Button { Task { await self.setup.load() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Check Again")
                    .disabled(!self.gateway.state.isConnected)
            }
            Spacer()
            #if os(macOS)
            Button("Close") { self.setup.close() }
                .keyboardShortcut(.cancelAction)
            #endif
            if status.isSkipped {
                Button("Unskip") { self.setup.unskip(step) }
            } else if !status.isDone {
                Button("Skip") { self.setup.skipCurrent() }
            }
            // On Test Message, Return sends from the text field; it mustn't also Finish.
            Button(self.setup.nextStep == nil ? "Finish" : "Continue") { self.setup.advance() }
                .keyboardShortcut(step == .testMessage ? nil : KeyboardShortcut.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }
}

/// "Needs Full Management" with the copy Gateway Settings uses, linking to Connection.
private struct FullManagementBadge: View {
    let openConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(SetupWizardModel.fullManagementTitle, systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
            Text(SetupWizardModel.fullManagementMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Connection…", action: self.openConnection)
                .buttonStyle(.borderless)
                .font(.callout)
        }
    }
}

private struct SetupLink: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Label(self.title, systemImage: self.symbol)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: Health

private struct SetupHealthStep: View {
    let openSettings: (SettingsDestination) -> Void
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let model = self.gateway.health
        let level = model.level
        Section {
            LabeledContent("Status") {
                Label(level.label, systemImage: level.symbol).foregroundStyle(GatewayHealthPage.color(level))
            }
            if let version = model.serverVersion { LabeledContent("Version", value: version) }
            ForEach(model.activeIssues) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Label(issue.title, systemImage: issue.symbol).foregroundStyle(.orange)
                    if let detail = issue.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            SetupLink(title: "Open Gateway Health", symbol: "stethoscope") { self.openSettings(.health) }
        }
    }
}

// MARK: Channels

private struct SetupChannelsStep: View {
    let setup: SetupWizardModel
    let openSettings: (SettingsDestination) -> Void

    var body: some View {
        let snapshot = self.setup.channelsSnapshot
        Section("Channels") {
            if let snapshot {
                if snapshot.channels.isEmpty {
                    Text("No channels yet. Add one in Gateway Settings → Channels.").foregroundStyle(.secondary)
                }
                ForEach(snapshot.channels) { channel in
                    SetupChannelRow(setup: self.setup, channel: channel,
                                    issues: snapshot.issues.filter { $0.channel == channel.id })
                }
            } else if let failure = self.setup.channelsFailure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            SetupLink(title: "Open Channels", symbol: "bubble.left.and.bubble.right") { self.openSettings(.page("channels")) }
        }
    }
}

private struct SetupChannelRow: View {
    let setup: SetupWizardModel
    let channel: GatewayChannelHealth
    let issues: [SetupChannelsSnapshot.Issue]

    var body: some View {
        let status = self.channel.status
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(self.channel.label) {
                Text(status.label).foregroundStyle(GatewayHealthPage.color(status))
            }
            if let error = self.channel.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(self.issues, id: \.self) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.message).font(.caption)
                    if let fix = issue.fix { Text(fix).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if SetupRules.supportsQRLogin(self.channel.id) {
                self.qrLogin
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var qrLogin: some View {
        let accountId = self.channel.accounts.count == 1 ? self.channel.accounts[0].accountId : nil
        let state = self.setup.qrLogin(channel: self.channel.id, accountId: accountId)
        switch state {
        case .idle, .failed:
            if case let .failed(message) = state {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            Button {
                self.setup.startQRLogin(channel: self.channel.id, accountId: accountId,
                                        force: self.channel.status == .connected)
            } label: {
                Label(self.channel.status == .connected ? "Relink with QR Code…" : "Link with QR Code…", systemImage: "qrcode")
            }
            .buttonStyle(.borderless)
            .disabled(!self.setup.canStartQRLogin(channel: self.channel.id))
        case .starting:
            ProgressView("Getting a QR code…").controlSize(.small)
        case let .showing(qr, message):
            VStack(alignment: .leading, spacing: 6) {
                if let image = PlatformImage(data: qr) {
                    Self.image(image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .accessibilityLabel("QR code for \(self.channel.label)")
                }
                Text(message ?? "Scan this with \(self.channel.label) on your phone to link it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { self.setup.cancelQRLogin(channel: self.channel.id, accountId: accountId) }
                    .buttonStyle(.borderless)
            }
        case let .connected(message):
            Label(message.map(Self.linkedMessage) ?? "Linked", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
            Button {
                self.setup.startQRLogin(channel: self.channel.id, accountId: accountId, force: true)
            } label: {
                Label("Relink with QR Code…", systemImage: "qrcode")
            }
            .buttonStyle(.borderless)
            .disabled(!self.setup.canStartQRLogin(channel: self.channel.id))
        }
    }

    /// Drops upstream's chat-agent hint ("Say “relink” …"): here it's the Relink button.
    static func linkedMessage(_ message: String) -> String {
        guard let range = message.range(of: " Say “relink”") else { return message }
        return String(message[..<range.lowerBound])
    }
}

extension SetupChannelRow {
    static func image(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

// MARK: Agent & Model

private struct SetupAgentStep: View {
    let setup: SetupWizardModel
    let openSettings: (SettingsDestination) -> Void
    @Environment(GatewayStore.self) private var gateway
    @State private var agentId: String?
    @State private var modelRef: String?
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        let gateway = self.gateway
        let agentId = self.agentId ?? gateway.defaultAgentId
        let catalog = gateway.modelCatalogs[agentId] ?? []
        let blocker = gateway.setupDefaultsBlocker
        Section("Defaults") {
            Picker("Default agent", selection: Binding(get: { agentId }, set: { self.agentId = $0; self.saved = false })) {
                ForEach(gateway.agents) { agent in
                    Text([agent.emoji, agent.name].compactMap(\.self).joined(separator: " ")).tag(agent.id)
                }
                if !gateway.agents.contains(where: { $0.id == agentId }) { Text(agentId).tag(agentId) }
            }
            Picker("Default model", selection: Binding(get: { self.modelRef ?? gateway.defaultModelRef },
                                                        set: { self.modelRef = $0; self.saved = false })) {
                if gateway.defaultModelRef == nil { Text("None").tag(String?.none) }
                ForEach(catalog) { model in
                    Text(model.isAvailable ? model.displayName : "\(model.displayName) (unavailable)").tag(Optional(model.ref))
                }
                if let current = gateway.defaultModelRef, !catalog.contains(where: { $0.ref == current }) {
                    Text(ModelRef.shortName(current)).tag(Optional(current))
                }
            }
            if gateway.loadingModelCatalogs.contains(agentId) { ProgressView().controlSize(.small) }
            if let blocker, !self.setup.needsFullManagement(.agent) {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(self.saved ? "Saved" : "Save Defaults") { self.save() }
                    .disabled(blocker != nil || self.saving || self.saved || !self.hasChanges)
                if self.saving { ProgressView().controlSize(.small) }
            }
            SetupLink(title: "Open Agents & Models", symbol: "person.2") { self.openSettings(.page("agents")) }
        }
        .task(id: agentId) { await gateway.loadModels(agentId: agentId) }
    }

    private var hasChanges: Bool {
        (self.agentId.map { $0 != self.gateway.defaultAgentId } ?? false)
            || (self.modelRef.map { $0 != self.gateway.defaultModelRef } ?? false)
    }

    private func save() {
        self.saving = true
        self.error = nil
        let agentId = self.agentId.flatMap { $0 == self.gateway.defaultAgentId ? nil : $0 }
        let modelRef = self.modelRef.flatMap { $0 == self.gateway.defaultModelRef ? nil : $0 }
        Task {
            self.error = await self.gateway.saveSetupDefaults(agentId: agentId, modelRef: modelRef)
            self.saving = false
            self.saved = self.error == nil
        }
    }
}

// MARK: Skills

private struct SetupSkillsStep: View {
    let setup: SetupWizardModel
    let openSettings: (SettingsDestination) -> Void

    var body: some View {
        Section("Skills") {
            if let report = self.setup.skills {
                let missing = report.missing
                if missing.isEmpty {
                    Label("Every skill has what it needs.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(missing) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(skill.name)
                        } icon: {
                            if let emoji = skill.emoji { Text(emoji) } else { Image(systemName: "puzzlepiece.extension") }
                        }
                        if !skill.missing.isEmpty {
                            Text("Needs \(skill.missing.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
                        }
                        if !skill.installOptions.isEmpty {
                            Text("Install: \(skill.installOptions.joined(separator: " · "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Ready", value: "\(report.ready.count)")
            } else if let failure = self.setup.skillsFailure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            SetupLink(title: "Open Tools & Skills", symbol: "wrench.and.screwdriver") { self.openSettings(.page("tools")) }
        }
    }
}

// MARK: Test message

private struct SetupTestMessageStep: View {
    let setup: SetupWizardModel
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @State private var text = SetupWizardModel.testMessageText
    @State private var sending = false
    @State private var error: String?
    @State private var sentKey: String?

    var body: some View {
        Section {
            TextField("Message", text: self.$text)
                .onSubmit(self.send)
            HStack {
                Button(self.text == SetupWizardModel.testMessageText ? "Send \u{201C}hello\u{201D}" : "Send", action: self.send)
                    .disabled(self.sending || !self.gateway.state.isConnected
                        || self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if self.sending { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let key = self.sentKey {
                Button("Open Chat") {
                    self.setup.close()
                    self.app.open(Notifier.Target(gatewayId: self.gateway.id, sessionKey: key))
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Starts a new chat with \(self.gateway.agent(self.gateway.defaultAgentId).name). The reply shows up there.")
        }
    }

    private func send() {
        guard !self.sending else { return }
        self.sending = true
        self.error = nil
        let text = self.text
        Task {
            let result = await self.gateway.sendSetupTestMessage(text)
            self.sending = false
            switch result.outcome {
            case .sent: self.sentKey = result.key
            case let .failed(message): self.error = message
            }
        }
    }
}

// MARK: Gateway Settings → Overview

/// "Set Up Gateway…" with the wizard's progress.
struct SetupGatewaySection: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.closeGatewaySettings) private var closeGatewaySettings

    var body: some View {
        let setup = self.gateway.setup
        Section {
            Button {
                self.open(setup)
            } label: {
                LabeledContent {
                    Text(setup.progress.completed ? "Done" : "\(setup.settledCount) of \(SetupStep.allCases.count)")
                } label: {
                    Label("Set Up Gateway…", systemImage: "checklist")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!self.gateway.state.isConnected)
        }
    }

    private func open(_ setup: SetupWizardModel) {
        #if os(macOS)
        setup.present()
        #else
        // Gateway Settings is a sheet here: the wizard shows once it's gone.
        self.closeGatewaySettings()
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            setup.present()
        }
        #endif
    }
}
