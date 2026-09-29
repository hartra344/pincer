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
    /// Inside the first-run wizard, which supplies the window, title and close button.
    var embedded = false
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
        .frame(width: self.embedded ? nil : 720, height: self.embedded ? nil : 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .task(id: self.gateway.state.isConnected) {
            guard self.gateway.state.isConnected else { return }
            await self.setup.load()
        }
    }

    @ViewBuilder private var steps: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            SetupStepList(setup: self.setup)
                .frame(width: 210)
            Divider()
            SetupStepDetail(setup: self.setup, openSettings: self.openSettings, embedded: self.embedded)
        }
        #else
        if self.embedded {
            VStack(spacing: 0) {
                SetupStepStrip(setup: self.setup)
                Divider()
                SetupStepDetail(setup: self.setup, openSettings: self.openSettings, embedded: true)
            }
        } else {
            self.navigationSteps
        }
        #endif
    }

    #if os(iOS)
    private var navigationSteps: some View {
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
    }
    #endif
}

private struct SetupIntroView: View {
    let setup: SetupWizardModel
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        VStack(spacing: Theme.Spacing.section) {
            Spacer(minLength: 0)
            Image(systemName: "checklist")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Set Up \(self.gateway.profile.name)")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Pick your default agent and model, look over skills, then send a test message. Skip anything you like.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(SetupStep.allCases) { step in
                    Label(step.title, systemImage: step.symbol)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            HStack(spacing: Theme.Spacing.xl) {
                Button("Not Now") { self.setup.notNow() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Setup") { self.setup.startSetup() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.hero)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Step list

private struct SetupStatusIcon: View {
    let status: SetupStepStatus
    let step: SetupStep

    var body: some View {
        Image(systemName: Self.isOptional(self.status, self.step) ? "info.circle" : self.status.symbol)
            .foregroundStyle(Self.color(self.status, self.step))
            .accessibilityLabel(Self.label(self.status, self.step))
    }

    /// Skills are informational: once checked they read "Optional", never Done or a demand.
    static func isOptional(_ status: SetupStepStatus, _ step: SetupStep) -> Bool {
        step == .skills && status.isDone
    }

    static func label(_ status: SetupStepStatus, _ step: SetupStep) -> String {
        self.isOptional(status, step) ? "Optional" : status.label
    }

    static func color(_ status: SetupStepStatus, _ step: SetupStep) -> Color {
        if self.isOptional(status, step) { return .secondary }
        switch status {
        case .done: return .green
        case .needsAttention: return .orange
        case .skipped, .notChecked: return .secondary
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
                .padding([.horizontal, .top], Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.lg)
            List(SetupStep.allCases, selection: Binding(get: { self.setup.currentStep },
                                                         set: { if let step = $0 { self.setup.currentStep = step } })) { step in
                let status = self.setup.status(of: step)
                HStack(spacing: Theme.Spacing.md) {
                    SetupStatusIcon(status: status, step: step)
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text(step.title)
                        Text(SetupStatusIcon.label(status, step)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Theme.Spacing.xxs)
                .tag(step)
            }
            .listStyle(.sidebar)
            Text("\(self.setup.settledCount) of \(SetupStep.allCases.count) done or skipped")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(Theme.Spacing.xxl)
        }
    }
}
#else
private struct SetupStepStrip: View {
    let setup: SetupWizardModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(SetupStep.allCases) { step in
                    let status = self.setup.status(of: step)
                    Button { self.setup.currentStep = step } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            SetupStatusIcon(status: status, step: step)
                            Text(step.title)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Capsule().fill(step == self.setup.currentStep ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(step.title), \(SetupStatusIcon.label(status, step))")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, Theme.Spacing.md)
        }
    }
}
#endif

// MARK: Step detail

private struct SetupStepDetail: View {
    let setup: SetupWizardModel
    let openSettings: (SettingsDestination) -> Void
    /// In first run: no Close or Check Again, so there are fewer ways out (product review r1).
    var embedded = false
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app

    var body: some View {
        let step = self.setup.currentStep
        let status = self.setup.status(of: step)
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                        Image(systemName: step.symbol).font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(step.heading).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                            HStack(spacing: Theme.Spacing.xs) {
                                SetupStatusIcon(status: status, step: step)
                                Text(SetupStatusIcon.label(status, step)).foregroundStyle(SetupStatusIcon.color(status, step))
                            }
                            .font(.callout)
                            Text(step.summary).font(.callout).foregroundStyle(.secondary)
                            // Test Message says where it's at next to the reply instead.
                            if step != .testMessage, let detail = status.detail ?? self.setup.evaluated(step).detail {
                                Text(detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if self.setup.needsFullManagement(step) {
                        FullManagementBadge { self.openSettings(.connection) }
                    }
                }
                switch step {
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

    /// Finish after a test message lands on its Setup Test chat.
    private func advance() {
        let chatKey = self.setup.nextStep == nil ? self.setup.testChatKey : nil
        self.setup.advance()
        if let chatKey { self.app.open(Notifier.Target(gatewayId: self.gateway.id, sessionKey: chatKey)) }
    }

    private func footer(step: SetupStep, status: SetupStepStatus) -> some View {
        HStack {
            Button("Back") { self.setup.goBack() }
                .disabled(self.setup.previousStep == nil)
            if self.setup.loadState.isRunning {
                ProgressView().controlSize(.small).padding(.leading, Theme.Spacing.xs)
            } else if !self.embedded {
                Button { Task { await self.setup.load() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Check Again")
                    .disabled(!self.gateway.state.isConnected)
            }
            Spacer()
            #if os(macOS)
            if !self.embedded {
                Button("Close") { self.setup.close() }
                    .keyboardShortcut(.cancelAction)
            }
            #endif
            if status.isSkipped {
                Button("Unskip") { self.setup.unskip(step) }
            } else if !status.isDone {
                Button("Skip") { self.setup.skipCurrent() }
            }
            // On Test Message, Return sends from the text field; it mustn't also Finish.
            Button(self.setup.nextStep == nil ? "Finish" : "Continue") { self.advance() }
                .keyboardShortcut(step == .testMessage ? nil : KeyboardShortcut.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.xl)
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
        .foregroundStyle(.tint)
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
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        Section("Skills") {
            if let report = self.setup.skills {
                let missing = report.missing
                if missing.isEmpty {
                    Label("Every skill has what it needs.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Text("Not set up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(missing) { skill in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Label {
                            Text(skill.name)
                        } icon: {
                            if let emoji = skill.emoji { Text(emoji) } else { Image(systemName: "puzzlepiece.extension") }
                        }
                        if !skill.missing.isEmpty {
                            Text("Needs \(skill.missing.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
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
            if self.gateway.supportsSkills {
                SetupLink(title: "Open Skills", symbol: "wand.and.stars") { self.openSettings(.skills) }
            } else {
                SetupLink(title: "Open Tools & Skills", symbol: "wrench.and.screwdriver") { self.openSettings(.page("tools")) }
            }
        }
    }
}

// MARK: Test message

private struct SetupTestMessageStep: View {
    let setup: SetupWizardModel
    @Environment(GatewayStore.self) private var gateway
    @State private var text = SetupWizardModel.testMessageText
    @State private var sending = false
    @State private var error: String?
    /// The Setup Test chat (`setup.testChatKey`), looked up outside `body` so it never creates a store.
    @State private var chat: ChatStore?

    var body: some View {
        let failed = self.error != nil || self.chat.map(SetupTestReply.failed) == true
        Section {
            TextField("Message", text: self.$text)
                .onSubmit(self.send)
            HStack {
                Button(failed ? "Try Again" : self.chat == nil ? "Send" : "Send Again", action: self.send)
                    .disabled(self.sending || !self.gateway.state.isConnected
                        || self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if self.sending { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let chat = self.chat {
                SetupTestReply(chat: chat)
            }
            // Finish opens this chat (no separate Open Chat, #175).
            Text(self.chat.map(SetupTestReply.replied) == true
                ? "Finish opens this chat."
                : "Pincer starts a chat called \(GatewayStore.setupTestLabel) with \(self.gateway.agent(self.gateway.defaultAgentId).name).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: self.setup.testChatKey) {
            self.chat = self.setup.testChatKey.map { self.gateway.chat(for: $0) }
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
            case .sent: break
            case let .failed(message), let .failedInline(message): self.error = message
            case .queued: self.error = "Couldn’t send: not connected to the Gateway."
            }
        }
    }
}

/// The agent's answer to the test message, as it streams in.
private struct SetupTestReply: View {
    let chat: ChatStore

    var body: some View {
        let reply = Self.reply(in: self.chat)
        if let reply, reply.isError {
            Label("Your agent didn't answer. You can try again, or skip and chat later.", systemImage: "exclamationmark.bubble")
                .foregroundStyle(.red)
        } else if let reply, !reply.body.isEmpty, !reply.isStreaming {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("Your agent replied.", systemImage: "checkmark.bubble.fill").foregroundStyle(.green)
                Text(Self.inline(reply.body)).lineLimit(4).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        } else if self.chat.errorMessage != nil {
            Label("Your agent didn't answer. You can try again, or skip and chat later.", systemImage: "exclamationmark.bubble")
                .foregroundStyle(.red)
        } else {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Sent. Waiting for your agent…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The agent's answer arrived (not an error, done streaming).
    static func replied(_ chat: ChatStore) -> Bool {
        guard let reply = self.reply(in: chat) else { return false }
        return !reply.isError && !reply.body.isEmpty && !reply.isStreaming
    }

    /// A preview of the reply: inline Markdown (bold, code, links) on plain lines, with heading
    /// marks, code fences and blank lines dropped and list markers as bullets.
    static func inline(_ markdown: String) -> AttributedString {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("~~~") { return nil }
            if line.hasPrefix("#") { line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line = "• " + line.dropFirst(2) }
            if line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return line
        }
        let text = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The agent answered with an error, or the send failed after it was accepted.
    static func failed(_ chat: ChatStore) -> Bool {
        self.reply(in: chat)?.isError == true || chat.errorMessage != nil
    }

    /// The last assistant turn after the last user message.
    static func reply(in chat: ChatStore) -> AssistantTurn? {
        for entry in chat.entries.reversed() {
            switch entry {
            case let .assistant(turn): return turn
            case .user: return nil
            case .marker: continue
            }
        }
        return nil
    }
}

// MARK: Gateway Settings → Overview

/// "Set Up Gateway…" with the wizard's progress.
struct SetupGatewaySection: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
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
        // The wizard is presented on the main window, for the selected gateway.
        self.app.selectedGatewayId = self.gateway.id
        #if os(macOS)
        setup.present()
        // Over Gateway Settings, not behind it (#131).
        QuickCaptureController.shared.showMainWindow()
        #else
        // Gateway Settings is a sheet here: the wizard shows once it's gone (#133).
        self.closeGatewaySettings { setup.present() }
        #endif
    }
}
