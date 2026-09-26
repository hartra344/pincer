import PincerKit
import SwiftUI

// MARK: Opening

/// Opens the Automations dashboard for a gateway: its own window on macOS, a sheet on iOS.
struct AutomationsOpener {
    var open: @MainActor (GatewayStore) -> Void = { _ in }

    @MainActor
    func callAsFunction(_ gateway: GatewayStore) { self.open(gateway) }
}

extension EnvironmentValues {
    @Entry var openAutomations = AutomationsOpener()
}

/// A request to show Automations in a sheet (iOS).
struct AutomationsRequest: Identifiable {
    let id: UUID
}

// MARK: Window

/// Cron jobs for one gateway: what's scheduled, how the last runs went, and controls to run,
/// pause, edit, create and delete them. The gateway is looked up on every render because
/// editing its connection replaces the `GatewayStore`.
struct AutomationsWindow: View {
    let gatewayId: UUID?
    /// iOS: closes the sheet.
    var close: (() -> Void)?
    @Environment(AppModel.self) private var app

    var body: some View {
        if let gateway = self.app.gateways.first(where: { $0.id == self.gatewayId }) {
            AutomationsRoot(close: self.close)
                .environment(gateway)
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

private struct AutomationsRoot: View {
    var close: (() -> Void)?
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selection: String?
    @State private var editing: CronJobDraft?
    @State private var deleting: CronJob?

    private var model: AutomationsModel { self.gateway.automations }

    var body: some View {
        let model = self.model
        Group {
            if !model.supported {
                ContentUnavailableView {
                    Label("Automations Aren't Available", systemImage: "clock.badge.xmark")
                } description: {
                    Text("This Gateway doesn't offer cron jobs to Pincer (`cron.*`). Update OpenClaw to manage automations here.")
                }
                .toolbar { self.doneButton }
            } else {
                NavigationSplitView {
                    self.list
                        #if os(macOS)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                        #endif
                        .toolbar { self.doneButton }
                } detail: {
                    if let job = model.job(self.selection) {
                        AutomationDetail(job: job, edit: { self.edit(job) }, delete: { self.deleting = job },
                                         openChat: self.openChat)
                            .id(job.id)
                    } else {
                        self.placeholder
                    }
                }
            }
        }
        .navigationTitle("Automations")
        #if os(macOS)
        .navigationSubtitle(self.gateway.profile.name)
        #endif
        .sheet(item: self.$editing) { draft in
            AutomationEditor(draft: draft) { saved in self.selection = saved }
                .environment(self.gateway)
        }
        .confirmationDialog("Delete “\(self.deleting?.name ?? "")”?", isPresented: Binding(
            get: { self.deleting != nil }, set: { if !$0 { self.deleting = nil } }
        ), titleVisibility: .visible, presenting: self.deleting) { job in
            Button("Delete Automation", role: .destructive) {
                Task {
                    if await model.remove(job), self.selection == job.id { self.selection = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It stops running and its run history is removed from the Gateway. Its chats stay.")
        }
        .task(id: self.gateway.state.isConnected) {
            if self.gateway.state.isConnected { await model.load() }
        }
    }

    @ToolbarContentBuilder private var doneButton: some ToolbarContent {
        if let close = self.close {
            ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
        }
    }

    private var list: some View {
        let model = self.model
        return List(selection: self.$selection) {
            if let scheduler = model.scheduler, !scheduler.enabled {
                Label("The Gateway's scheduler is off, so automations only run when you start them.",
                      systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            ForEach(model.jobs) { job in
                AutomationRow(job: job)
                    .tag(job.id)
                    .contextMenu { self.menu(job) }
            }
        }
        .overlay {
            if !model.hasLoaded || (model.jobs.isEmpty && model.loadState.isRunning) {
                ProgressView()
            } else if let error = model.loadState.error, model.jobs.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Automations", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                }
            } else if model.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Automations", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Automations run an agent on a schedule, like a morning briefing or a nightly check.")
                } actions: {
                    if model.canEdit { Button("New Automation…", action: self.create) }
                }
            }
        }
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!self.gateway.state.isConnected || model.loadState.isRunning)
            }
            ToolbarItem {
                Button(action: self.create) { Label("New Automation", systemImage: "plus") }
                    .disabled(!self.gateway.state.isConnected || !model.canEdit)
                    .help(model.canEdit ? "New Automation" : "Needs Full Management access")
            }
        }
    }

    @ViewBuilder private func menu(_ job: CronJob) -> some View {
        let model = self.model
        Button("Run Now", systemImage: "play") { Task { await model.runNow(job) } }
            .disabled(!model.canEdit)
        Button(job.enabled ? "Pause" : "Resume", systemImage: job.enabled ? "pause" : "playpause") {
            Task { await model.setEnabled(job, !job.enabled) }
        }
        .disabled(!model.canEdit)
        Button("Edit…", systemImage: "pencil") { self.edit(job) }
            .disabled(!model.canEdit)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { self.deleting = job }
            .disabled(!model.canEdit)
    }

    private var placeholder: some View {
        let model = self.model
        return ContentUnavailableView {
            Label("Pick an Automation", systemImage: "clock.arrow.circlepath")
        } description: {
            if let next = model.scheduler?.nextWakeAt, model.scheduler?.enabled != false {
                Text("\(model.jobs.count) automation\(model.jobs.count == 1 ? "" : "s"). The next one runs \(next.formatted(.relative(presentation: .named))).")
            } else {
                Text("See when each one runs next, how its last runs went, and open the chats they ran in.")
            }
        }
    }

    private func create() {
        self.editing = CronJobDraft(agentId: self.gateway.defaultAgentId)
    }

    private func edit(_ job: CronJob) {
        self.model.clearError(for: job.id)
        self.editing = CronJobDraft(job: job, defaultAgentId: self.gateway.defaultAgentId)
    }

    /// Shows a chat in the main window.
    private func openChat(_ key: String) {
        self.app.open(Notifier.Target(gatewayId: self.gateway.id, sessionKey: key))
        #if os(macOS)
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            self.openWindow(id: "main")
        }
        #else
        self.close?()
        #endif
    }
}

// MARK: Rows

private struct AutomationRow: View {
    let job: CronJob

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AutomationHealthIcon(health: self.job.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.job.name)
                    .lineLimit(1)
                    .foregroundStyle(self.job.enabled ? .primary : .secondary)
                Text(self.job.schedule.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(self.job.health == .failing ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch self.job.health {
        case .running: return "Running now"
        case .paused: return "Paused"
        case .failing:
            return self.job.consecutiveErrors > 1 ? "Failed \(self.job.consecutiveErrors) times in a row" : "Last run failed"
        default:
            if let next = self.job.nextRunAt { return "Next \(next.formatted(.relative(presentation: .named)))" }
            if let last = self.job.lastRunAt { return "Ran \(last.formatted(.relative(presentation: .named)))" }
            return "Not scheduled"
        }
    }
}

private struct AutomationHealthIcon: View {
    let health: CronJob.Health

    var body: some View {
        Image(systemName: self.symbol)
            .foregroundStyle(self.color)
            .accessibilityLabel(self.label)
    }

    private var symbol: String {
        switch self.health {
        case .paused: "pause.circle.fill"
        case .running: "circle.dotted.circle"
        case .failing: "exclamationmark.circle.fill"
        case .ok: "checkmark.circle.fill"
        case .skipped: "forward.circle.fill"
        case .idle: "clock"
        }
    }

    private var color: Color {
        switch self.health {
        case .paused, .idle, .skipped: .secondary
        case .running: .blue
        case .failing: .red
        case .ok: .green
        }
    }

    private var label: String {
        switch self.health {
        case .paused: "Paused"
        case .running: "Running"
        case .failing: "Failing"
        case .ok: "Last run succeeded"
        case .skipped: "Last run skipped"
        case .idle: "Hasn't run yet"
        }
    }
}

private struct RunOutcomeIcon: View {
    let status: CronRunOutcome?

    var body: some View {
        switch self.status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Succeeded")
        case .error: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .skipped: Image(systemName: "forward.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Skipped")
        case nil: Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("Unknown")
        }
    }
}

// MARK: Detail

private struct AutomationDetail: View {
    let job: CronJob
    let edit: () -> Void
    let delete: () -> Void
    let openChat: (String) -> Void
    @Environment(GatewayStore.self) private var gateway

    private var model: AutomationsModel { self.gateway.automations }

    var body: some View {
        let model = self.model
        let job = self.job
        let operation = model.operation(for: job.id)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        AutomationHealthIcon(health: job.health)
                        Text(job.name).font(.title3.weight(.semibold))
                    }
                    if let description = job.description {
                        Text(description).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                self.actions(operation: operation)
                if let error = operation.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                } else if !model.canEdit {
                    Text("Running, pausing and editing automations needs Full Management access (Gateway Settings → Connection).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Schedule") {
                LabeledContent("Runs", value: job.schedule.summary)
                LabeledContent("Next run") {
                    if !job.enabled {
                        Text("Paused")
                    } else if let next = job.nextRunAt {
                        DateText(date: next)
                    } else {
                        Text("Not scheduled")
                    }
                }
                LabeledContent("Last run") {
                    if let running = job.runningSince {
                        Text("Running since \(running.formatted(date: .omitted, time: .shortened))")
                    } else if let last = job.lastRunAt {
                        DateText(date: last, duration: job.lastDurationMs)
                    } else {
                        Text("Never")
                    }
                }
                if let error = job.lastError, job.lastStatus == .error {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.consecutiveErrors > 1 ? "Failed \(job.consecutiveErrors) times in a row" : "Last error")
                            .font(.callout.weight(.medium))
                        Text(error)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.red)
                }
            }

            Section("Task") {
                LabeledContent("Agent", value: self.agentName)
                LabeledContent("Runs in", value: self.target)
                if let text = job.payloadText {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
                if let delivery = self.delivery {
                    LabeledContent("Results", value: delivery)
                }
                let chatKey = job.chatKey(defaultAgentId: self.gateway.defaultAgentId)
                if self.gateway.sessions[chatKey] != nil {
                    Button("Open Automation Chat", systemImage: "bubble.left.and.text.bubble.right") { self.openChat(chatKey) }
                }
            }

            Section {
                self.history
            } header: {
                HStack {
                    Text("Run History")
                    Spacer()
                    if model.runsState[job.id]?.isRunning == true { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(job.name)
        .task(id: RunsKey(id: job.id, lastRun: job.lastRunAt, running: job.runningSince)) {
            await model.loadRuns(for: job.id)
        }
    }

    private struct RunsKey: Hashable {
        let id: String
        let lastRun: Date?
        let running: Date?
    }

    @ViewBuilder private func actions(operation: OperationState) -> some View {
        let model = self.model
        let job = self.job
        let disabled = !model.canEdit || operation.isRunning || !self.gateway.state.isConnected
        HStack {
            Button("Run Now", systemImage: "play.fill") { Task { await model.runNow(job) } }
                .glassProminentButton()
            Button(job.enabled ? "Pause" : "Resume", systemImage: job.enabled ? "pause.fill" : "playpause.fill") {
                Task { await model.setEnabled(job, !job.enabled) }
            }
            .glassButton()
            Button("Edit…", systemImage: "pencil", action: self.edit)
                .glassButton()
            Spacer()
            if operation.isRunning { ProgressView().controlSize(.small) }
            Button("Delete…", systemImage: "trash", role: .destructive, action: self.delete)
                .labelStyle(.iconOnly)
                .glassButton()
                .help("Delete Automation")
        }
        .disabled(disabled)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var history: some View {
        let model = self.model
        let runs = model.runs[self.job.id] ?? []
        if let error = model.runsState[self.job.id]?.error, runs.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            Button("Try Again") { Task { await model.loadRuns(for: self.job.id) } }
        } else if runs.isEmpty {
            Text(model.runs[self.job.id] == nil ? "Loading…" : "No runs yet.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(runs) { run in
                RunRow(run: run, openChat: self.openChat)
            }
        }
    }

    private var agentName: String {
        let id = self.job.agentId ?? self.gateway.defaultAgentId
        guard let agent = self.gateway.agents.first(where: { $0.id == id }) else { return id }
        return "\(agent.emoji.map { "\($0) " } ?? "")\(agent.name)"
    }

    private var target: String {
        switch self.job.sessionTarget {
        case "isolated": "Its own chat"
        case "main": "The agent's main chat"
        case "current": "The chat it was created in"
        case let target where target.hasPrefix("session:"): String(target.dropFirst("session:".count))
        case let target: target
        }
    }

    private var delivery: String? {
        switch self.job.deliveryMode {
        case "announce":
            let target = self.job.deliveryTarget == "last" || self.job.deliveryTarget == nil
                ? "the last channel" : self.job.deliveryTarget ?? ""
            return "Posted to \(target)"
        case "webhook": return "Sent to a webhook"
        case "none": return "Kept in the chat"
        default: return nil
        }
    }
}

/// A date as "in 5 min · Sep 26, 10:00", optionally with how long the run took.
private struct DateText: View {
    let date: Date
    var duration: Int?

    var body: some View {
        var text = "\(self.date.formatted(.relative(presentation: .named))) · \(self.date.formatted(date: .abbreviated, time: .shortened))"
        if let duration { text += " · \(RunRow.duration(duration))" }
        return Text(text)
    }
}

private struct RunRow: View {
    let run: CronRun
    let openChat: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RunOutcomeIcon(status: self.run.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let duration = self.run.durationMs {
                        Text(Self.duration(duration)).foregroundStyle(.secondary)
                    }
                    if let model = self.run.model {
                        Text(model).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                if let error = self.run.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                } else if let summary = self.run.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
            if let key = self.run.sessionKey {
                Button("Open Chat") { self.openChat(key) }
                    .buttonStyle(.borderless)
                    .help("Show the chat this run happened in")
            }
        }
    }

    static func duration(_ ms: Int) -> String {
        Duration.milliseconds(ms).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

// MARK: Editor

private struct AutomationEditor: View {
    @State var draft: CronJobDraft
    var onSaved: (String) -> Void
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    private var model: AutomationsModel { self.gateway.automations }
    private var operationKey: String { self.draft.original?.id ?? AutomationsModel.newJobKey }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: self.$draft.name, prompt: Text("e.g. Morning briefing"))
                    TextField("Description", text: self.$draft.description, prompt: Text("Optional"))
                    Picker("Agent", selection: self.$draft.agentId) {
                        ForEach(self.gateway.agents) { agent in
                            Text("\(agent.emoji.map { "\($0) " } ?? "")\(agent.name)").tag(agent.id)
                        }
                        if !self.gateway.agents.contains(where: { $0.id == self.draft.agentId }) {
                            Text(self.draft.agentId).tag(self.draft.agentId)
                        }
                    }
                    Toggle("Enabled", isOn: self.$draft.enabled)
                }
                self.scheduleSection
                self.taskSection
                if let error = self.model.operation(for: self.operationKey).error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(self.draft.isNew ? "New Automation" : "Edit Automation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        self.model.clearError(for: self.operationKey)
                        self.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(self.draft.isNew ? "Create" : "Save", action: self.save)
                        .disabled(self.saving || self.draft.problem != nil || !self.draft.hasChanges)
                        .help(self.draft.problem ?? "")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .onAppear { self.model.clearError(for: self.operationKey) }
    }

    @ViewBuilder private var scheduleSection: some View {
        if self.draft.isScheduleEditable {
            Section {
                Picker("Schedule", selection: self.$draft.scheduleKind) {
                    ForEach(CronJobDraft.ScheduleKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch self.draft.scheduleKind {
                case .every:
                    HStack {
                        Stepper(value: self.$draft.everyAmount, in: 1...10_000) {
                            LabeledContent("Every") {
                                TextField("Every", value: self.$draft.everyAmount, format: .number)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 80)
                            }
                        }
                        Picker("Unit", selection: self.$draft.everyUnit) {
                            ForEach(CronJobDraft.Unit.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                case .cron:
                    TextField("Expression", text: self.$draft.cronExpr, prompt: Text("0 7 * * *"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    TextField("Time zone", text: self.$draft.timeZone, prompt: Text(TimeZone.current.identifier))
                        .autocorrectionDisabled()
                case .at:
                    DatePicker("Run at", selection: self.$draft.runAt)
                }
            } header: {
                Text("Schedule")
            } footer: {
                if self.draft.scheduleKind == .cron {
                    Text("Minute, hour, day of month, month and day of week. Leave the time zone empty to use the Gateway's.")
                }
            }
        } else {
            Section("Schedule") {
                LabeledContent("Runs", value: self.draft.original?.schedule.summary ?? "")
                Text("This schedule can only be changed in the Control UI or the config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var taskSection: some View {
        if self.draft.isTaskEditable {
            Section {
                Picker("Runs in", selection: self.$draft.target) {
                    ForEach(CronJobDraft.Target.allCases) { Text($0.label).tag($0) }
                }
                TextField(self.draft.target == .main ? "Event" : "Instructions", text: self.$draft.message,
                          prompt: Text(self.draft.target == .main ? "Text posted to the main chat" : "What should the agent do?"),
                          axis: .vertical)
                    .lineLimit(3...10)
                if self.draft.target == .isolated {
                    Toggle(isOn: self.$draft.announce) {
                        Text("Post the result")
                        Text(self.announceDetail)
                    }
                }
            } header: {
                Text("Task")
            } footer: {
                Text(self.draft.target == .main
                    ? "The text arrives in the agent's main chat as a system event."
                    : "Each run starts a fresh chat under Automations in the sidebar.")
            }
        } else {
            Section("Task") {
                Text("This automation runs a \(self.draft.original?.payloadKind ?? "custom") task, which can only be changed in the Control UI or the config.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var announceDetail: String {
        if let target = self.draft.original?.deliveryTarget, target != "last", self.draft.original?.deliveryMode == "announce" {
            return "To \(target)."
        }
        return "To the last channel the agent used."
    }

    private func save() {
        self.saving = true
        Task {
            let saved = await self.model.save(self.draft)
            self.saving = false
            if let saved {
                self.onSaved(saved)
                self.dismiss()
            }
        }
    }
}
