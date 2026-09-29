import PincerKit
import SwiftUI

// Gateway Settings → Sessions: every session by Active / Archived / All, with a quick preview,
// run status and duration, multi-select archive/unarchive/delete, and a detail page with the
// session's branches and rewind points. Reading needs `operator.read`; archiving and deleting
// archived sessions need write; deleting live sessions, switching branches and rewinding need
// Full Management.

// MARK: Sessions page

struct SessionsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var filter: SessionManagerFilter = .active
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var confirmingDelete = false

    private var model: SessionManagerModel { self.gateway.sessionManager }

    private struct LoadKey: Hashable {
        let connected: Bool
        let filter: SessionManagerFilter
    }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        let rows = model.visibleRows(search: self.search)
        VStack(spacing: 0) {
            self.header(model, connected: connected)
            Divider()
            self.content(model, rows: rows, connected: connected)
            #if os(macOS)
            if self.selection.count == 1, let key = self.selection.first, let row = model.row(key) {
                Divider()
                SessionPreviewPanel(model: model, row: row)
                    .frame(height: 170)
                    .overlay(alignment: .topTrailing) {
                        Button("Details…") { self.open(key) }
                            .padding(Theme.Spacing.md)
                    }
            }
            #endif
            if !self.selection.isEmpty {
                Divider()
                self.actionBar(model)
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load(filter: self.filter) }
                }
                .disabled(!connected || model.isLoading)
            }
        }
        .confirmationDialog(SessionManager.deleteTitle(count: self.selection.count,
                                                        title: self.selection.first.flatMap(model.row)?.title),
                            isPresented: self.$confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let keys = Array(self.selection)
                Task {
                    let outcome = await model.delete(keys)
                    if outcome.failed.isEmpty, !self.selection.isEmpty { self.selection = [] }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SessionManager.deleteMessage)
        }
        .onAppear { model.clearMessages() }
        .onChange(of: rows.map(\.key)) { _, keys in
            let kept = self.selection.intersection(keys)
            if kept != self.selection { self.selection = kept }
        }
        .task(id: LoadKey(connected: connected, filter: self.filter)) {
            guard connected else { return }
            await model.loadIfNeeded(filter: self.filter)
        }
    }

    @ViewBuilder private func header(_ model: SessionManagerModel, connected: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Picker("Show", selection: Binding(
                get: { self.filter },
                set: { next in
                    guard next != self.filter else { return }
                    self.filter = next
                    if !self.selection.isEmpty { self.selection = [] }
                }
            )) {
                ForEach(SessionManagerFilter.allCases) { filter in Text(filter.title).tag(filter) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Filter sessions", text: self.$search)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            SessionManagerMessages(model: model)
        }
        .padding(Theme.Spacing.xl)
        .disabled(!connected)
    }

    @ViewBuilder private func content(_ model: SessionManagerModel, rows: [SessionRow], connected: Bool) -> some View {
        if !connected {
            ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                   description: Text("Connect to the Gateway to manage sessions."))
        } else if !model.supportsList {
            ContentUnavailableView("Session Management Isn't Available", systemImage: "rectangle.stack",
                                   description: Text(SessionManager.unsupportedMessage))
        } else if !model.hasLoaded, let error = model.loadError {
            ContentUnavailableView {
                Label("Couldn't Load Sessions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.load(filter: self.filter) } }
            }
        } else if !model.hasLoaded || (model.isLoading && model.filter != self.filter) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(self.search.isEmpty ? self.filter.emptyMessage : "No Matches",
                                   systemImage: self.filter == .archived ? "archivebox" : "rectangle.stack")
        } else {
            List(selection: self.$selection) {
                ForEach(rows) { row in
                    SessionManagerRowView(row: row, isBusy: model.busy.contains(row.key))
                        .tag(row.key)
                }
            }
            .contextMenu(forSelectionType: String.self) { keys in
                self.contextMenu(model, keys: keys)
            } primaryAction: { keys in
                if keys.count == 1, let key = keys.first { self.open(key) }
            }
            #if os(macOS)
            .onDeleteCommand { if self.canDelete(model) { self.confirmingDelete = true } }
            #endif
        }
    }

    @ViewBuilder private func contextMenu(_ model: SessionManagerModel, keys: Set<String>) -> some View {
        if keys.count == 1, let key = keys.first {
            Button("Show Details") { self.open(key) }
            Button("Copy Session Key") { Clipboard.copy(key) }
            Divider()
        }
        if !keys.isEmpty {
            let rows = keys.compactMap(model.row)
            if model.supportsArchive, rows.contains(where: { !$0.isArchived }) {
                Button("Archive") { Task { await self.setArchived(model, Array(keys), archived: true) } }
            }
            if model.supportsArchive, rows.contains(where: \.isArchived) {
                Button("Unarchive") { Task { await self.setArchived(model, Array(keys), archived: false) } }
            }
            if model.supportsDelete {
                Button("Delete…", role: .destructive) {
                    if self.selection != keys { self.selection = keys }
                    self.confirmingDelete = true
                }
                .disabled(!model.deletePlan(keys).canDelete)
            }
        }
    }

    private func actionBar(_ model: SessionManagerModel) -> some View {
        let rows = self.selection.compactMap(model.row)
        let plan = model.deletePlan(self.selection)
        let keys = Array(self.selection)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                Text("\(self.selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.supportsArchive {
                    Button("Archive", systemImage: "archivebox") {
                        Task { await self.setArchived(model, keys, archived: true) }
                    }
                    .disabled(model.isWorking || !rows.contains { !$0.isArchived })
                    Button("Unarchive", systemImage: "tray.and.arrow.up") {
                        Task { await self.setArchived(model, keys, archived: false) }
                    }
                    .disabled(model.isWorking || !rows.contains(where: \.isArchived))
                }
                if model.supportsDelete {
                    Button("Delete…", systemImage: "trash", role: .destructive) { self.confirmingDelete = true }
                        .disabled(model.isWorking || !plan.canDelete)
                }
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            if model.supportsDelete, plan.needsAdmin {
                Text(SessionManager.mixedDeleteMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FullManagementBadge { self.navigator.destination = .connection }
            }
        }
        .padding(Theme.Spacing.xl)
    }

    /// Archives or unarchives, clearing the selection once every key succeeded.
    private func setArchived(_ model: SessionManagerModel, _ keys: [String], archived: Bool) async {
        let outcome = await model.setArchived(keys, archived: archived)
        if outcome.failed.isEmpty, !self.selection.isEmpty { self.selection = [] }
    }

    private func canDelete(_ model: SessionManagerModel) -> Bool {
        model.supportsDelete && !model.isWorking && model.deletePlan(self.selection).canDelete
    }

    private func open(_ key: String) {
        self.navigator.path.append(.sessionDetail(key))
    }
}

// MARK: Row

/// Title, archived badge, agent · channel · last active, and the latest run's status and duration.
struct SessionManagerRowView: View {
    let row: SessionRow
    var isBusy = false

    var body: some View {
        let state = SessionRunState(row: self.row)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(self.row.title).lineLimit(1).truncationMode(.middle)
                    if self.row.isArchived {
                        Text("Archived")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, Theme.Spacing.hairline)
                            .background(.quaternary, in: Capsule())
                    }
                    if SessionManager.isRecoverable(self.row) {
                        Label("Interrupted", systemImage: "exclamationmark.arrow.circlepath")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .help("Interrupted by a Gateway restart")
                    }
                }
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if self.isBusy {
                ProgressView().controlSize(.small)
            } else {
                SessionRunStatusView(row: self.row, state: state)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [self.row.agentId]
        if let channel = self.row.channel, !channel.isEmpty { parts.append(channel) }
        if let date = self.row.activityDate { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

/// "Running · 12s" (ticking), "Done · 2m 5s", "Error".
struct SessionRunStatusView: View {
    let row: SessionRow
    let state: SessionRunState

    var body: some View {
        if self.state.isActive {
            TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { context in
                self.label(duration: SessionManager.runDuration(self.row, now: context.date))
            }
        } else if self.state != .idle {
            self.label(duration: SessionManager.runDuration(self.row, now: .distantPast))
        }
    }

    private func label(duration: TimeInterval?) -> some View {
        let text = duration.map { "\(self.state.title) · \(SessionManager.formatDuration($0))" } ?? self.state.title
        return Label(text, systemImage: self.symbol)
            .font(.caption.monospacedDigit())
            .foregroundStyle(self.color)
            .labelStyle(.titleAndIcon)
    }

    private var symbol: String {
        switch self.state {
        case .running: "play.circle.fill"
        case .queued: "clock"
        case .done: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .killed: "stop.circle"
        case .timeout: "hourglass"
        case .idle: "circle"
        }
    }

    private var color: Color {
        if self.state.isError { return .red }
        if self.state.isActive { return .accentColor }
        return .secondary
    }
}

// MARK: Preview

/// A session's last few messages from `sessions.preview`, loaded after a short pause on selection.
struct SessionPreviewPanel: View {
    let model: SessionManagerModel
    let row: SessionRow

    var body: some View {
        ScrollView {
            SessionPreviewContent(model: self.model, key: self.row.key)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.xl)
        }
        .task(id: PreviewLoad(key: self.row.key, isMissing: self.model.previews[self.row.key] == nil)) {
            guard self.model.previews[self.row.key] == nil else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self.model.loadPreview(key: self.row.key)
        }
    }
}

/// Re-runs a preview load when the key changes or its cached preview was dropped.
private struct PreviewLoad: Hashable {
    let key: String
    let isMissing: Bool
}

struct SessionPreviewContent: View {
    let model: SessionManagerModel
    let key: String

    var body: some View {
        if !self.model.supportsPreview {
            Text("Previews need a newer Gateway.").foregroundStyle(.secondary)
        } else if let preview = self.model.previews[self.key] {
            if preview.items.isEmpty {
                Text(preview.emptyReason ?? "No messages yet").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(preview.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                            Text(Self.roleTitle(item.role))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(item.text)
                                .font(.callout)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        } else if let error = self.model.previewErrors[self.key] {
            Text(error).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    static func roleTitle(_ role: String) -> String {
        switch role {
        case "user": "You"
        case "assistant": "Assistant"
        case "tool": "Tool"
        case "system": "System"
        default: role.capitalized
        }
    }
}

// MARK: Messages

/// The last action's result ("Archived 3 sessions"), error and per-session failures.
private struct SessionManagerMessages: View {
    let model: SessionManagerModel

    var body: some View {
        if let error = self.model.actionError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        } else if let message = self.model.lastMessage {
            Label(message, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let editorText = self.model.lastEditorText, !editorText.isEmpty {
            Text("The rewound message is back in the composer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(self.model.lastFailures, id: \.key) { failure in
            Text("\(failure.key): \(failure.message)")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if self.model.deniedAdmin {
            Text(SessionManager.needsAdminMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Detail

struct SessionDetailPage: View {
    let sessionKey: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirmingDelete = false
    @State private var pendingBranch: SessionBranch?
    @State private var pendingRewind: SessionRewindPoint?

    private var model: SessionManagerModel { self.gateway.sessionManager }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        let row = model.details[self.sessionKey] ?? model.row(self.sessionKey) ?? self.gateway.sessions[self.sessionKey]
        Form {
            if !model.hasAdmin, model.supportsRewind || model.supportsBranchSwitch || model.supportsDelete {
                Section { FullManagementBadge { self.navigator.destination = .connection } }
            }
            Section { SessionManagerMessages(model: model) }
            if let row {
                self.details(row, model: model)
                Section("Preview") { SessionPreviewContent(model: model, key: self.sessionKey) }
                self.actions(row, model: model, connected: connected)
                self.branches(row, model: model, connected: connected)
                self.rewindPoints(row, model: model, connected: connected)
            } else if let error = model.detailErrors[self.sessionKey] {
                Section { Text(error).foregroundStyle(.secondary) }
            } else {
                Section { ProgressView() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(row?.title ?? "Session")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await self.load(model, force: true) } }
                    .disabled(!connected)
            }
        }
        .confirmationDialog(SessionManager.deleteTitle(count: 1, title: row?.title), isPresented: self.$confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    let outcome = await model.delete([self.sessionKey])
                    if outcome.succeeded.contains(self.sessionKey) { self.pop() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SessionManager.deleteMessage)
        }
        .confirmationDialog(SessionManager.switchTitle(self.pendingBranch?.title ?? ""),
                            isPresented: Self.presence(self.$pendingBranch), titleVisibility: .visible,
                            presenting: self.pendingBranch) { branch in
            Button("Switch Branch") {
                Task { await model.switchBranch(key: self.sessionKey, leafEntryId: branch.leafEntryId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(SessionManager.switchMessage)
        }
        .confirmationDialog(SessionManager.rewindTitle(row?.title ?? "Session"),
                            isPresented: Self.presence(self.$pendingRewind), titleVisibility: .visible,
                            presenting: self.pendingRewind) { point in
            Button("Rewind", role: .destructive) {
                Task { await model.rewind(key: self.sessionKey, entryId: point.entryId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(SessionManager.rewindMessage)
        }
        .onAppear { model.clearMessages() }
        .task(id: connected) {
            guard connected else { return }
            await self.load(model, force: false)
        }
        .task(id: DetailReload(connected: connected, previewMissing: model.previews[self.sessionKey] == nil,
                               pointsMissing: model.rewindPoints[self.sessionKey] == nil)) {
            // After a rewind, switch or `sessions.changed` drops them, fetch them again.
            guard connected else { return }
            if model.previews[self.sessionKey] == nil, model.previewErrors[self.sessionKey] == nil {
                await model.loadPreview(key: self.sessionKey)
            }
            if model.rewindPoints[self.sessionKey] == nil, model.rewindErrors[self.sessionKey] == nil,
               !model.busy.contains(self.sessionKey) {
                await model.loadRewindPoints(key: self.sessionKey)
            }
        }
    }

    private struct DetailReload: Hashable {
        let connected: Bool
        let previewMissing: Bool
        let pointsMissing: Bool
    }

    /// Details and branches; the preview and rewind points load in the `DetailReload` task.
    /// Refresh (`force`) drops and refetches all of them and the list.
    private func load(_ model: SessionManagerModel, force: Bool) async {
        async let details: Void = model.loadDetails(key: self.sessionKey)
        async let branches: Void = model.loadBranches(key: self.sessionKey)
        guard force else {
            _ = await (details, branches)
            return
        }
        async let preview: Void = model.reloadPreview(key: self.sessionKey)
        async let points: Void = model.loadRewindPoints(key: self.sessionKey)
        _ = await (details, branches, preview, points)
        await model.reload()
    }

    @ViewBuilder private func details(_ row: SessionRow, model: SessionManagerModel) -> some View {
        Section("Details") {
            LabeledContent("Status") { SessionRunStatusView(row: row, state: SessionRunState(row: row)) }
            LabeledContent("Agent", value: row.agentId)
            if let channel = row.channel, !channel.isEmpty { LabeledContent("Channel", value: channel) }
            if let model = row.modelRef { LabeledContent("Model", value: ModelRef.shortName(model)) }
            if let tokens = row.totalTokens { LabeledContent("Context", value: "\(tokens.formatted()) tokens") }
            if let input = row.raw["inputTokens"]?.double, let output = row.raw["outputTokens"]?.double {
                LabeledContent("Last Run Tokens", value: "\(Int(input).formatted()) in · \(Int(output).formatted()) out")
            }
            if let branches = model.branches[row.key], !branches.isEmpty {
                LabeledContent("Branches", value: branches.count.formatted())
            }
            if let created = Self.date(row.raw["createdAt"]) {
                LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
            }
            if let active = row.activityDate {
                LabeledContent("Last Active", value: active.formatted(.relative(presentation: .named)))
            }
            if row.isArchived {
                LabeledContent("Archived") {
                    Text(Self.date(row.raw["archivedAt"])?.formatted(date: .abbreviated, time: .shortened) ?? "Yes")
                }
                if let reason = row.raw["archiveReason"]?.text { LabeledContent("Archive Reason", value: reason) }
            }
            if SessionManager.isRecoverable(row) {
                Label("Interrupted by a Gateway restart", systemImage: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Key") {
                Text(row.key).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let sessionId = row.sessionId {
                LabeledContent("Session ID") {
                    Text(sessionId).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func actions(_ row: SessionRow, model: SessionManagerModel, connected: Bool) -> some View {
        let busy = model.busy.contains(row.key)
        Section("Actions") {
            if model.canRecover(row) {
                Button("Recover Session", systemImage: "arrow.uturn.backward.circle") {
                    Task {
                        if let result = await model.recover(key: row.key), result.key != self.sessionKey {
                            self.replace(with: result.key)
                        }
                    }
                }
                .disabled(!connected || busy)
            }
            if model.supportsArchive {
                Button(row.isArchived ? "Unarchive" : "Archive",
                       systemImage: row.isArchived ? "tray.and.arrow.up" : "archivebox") {
                    Task { _ = await model.setArchived([row.key], archived: !row.isArchived) }
                }
                .disabled(!connected || busy)
            }
            if model.supportsDelete {
                let plan = model.deletePlan([row.key])
                Button("Delete…", systemImage: "trash", role: .destructive) { self.confirmingDelete = true }
                    .disabled(!connected || busy || !plan.canDelete)
                if plan.needsAdmin {
                    Text(SessionManager.mixedDeleteMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func branches(_ row: SessionRow, model: SessionManagerModel, connected: Bool) -> some View {
        Section("Branches") {
            if !model.supportsBranches {
                Text(SessionManager.branchesUnsupportedMessage).foregroundStyle(.secondary)
            } else if let branches = model.branches[row.key] {
                if branches.isEmpty {
                    Text("No branches").foregroundStyle(.secondary)
                }
                ForEach(branches) { branch in
                    HStack {
                        Image(systemName: branch.active ? "checkmark.circle.fill" : "arrow.triangle.branch")
                            .foregroundStyle(branch.active ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(branch.title).lineLimit(2)
                            Text(Self.branchSubtitle(branch)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !branch.active, model.supportsBranchSwitch {
                            Button("Switch…") { self.pendingBranch = branch }
                                .disabled(!connected || !model.canSwitchBranch || model.busy.contains(row.key))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(branch.active ? "Active" : "")
                }
            } else if let error = model.branchErrors[row.key] {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private func rewindPoints(_ row: SessionRow, model: SessionManagerModel, connected: Bool) -> some View {
        if model.supportsRewind {
            Section {
                if let points = model.rewindPoints[row.key] {
                    if points.isEmpty { Text("No messages to rewind to").foregroundStyle(.secondary) }
                    ForEach(points) { point in
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(point.text).lineLimit(2)
                                if let date = point.timestamp {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Rewind…") { self.pendingRewind = point }
                                .disabled(!connected || !model.canRewind || row.isArchived || row.hasActiveRun
                                    || model.busy.contains(row.key))
                        }
                    }
                } else if let error = model.rewindErrors[row.key] {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("Rewind")
            } footer: {
                if row.isArchived {
                    Text("Unarchive the session to rewind it.")
                } else if row.hasActiveRun {
                    Text("Wait for the current run to finish to rewind.")
                } else {
                    Text(SessionManager.rewindMessage)
                }
            }
        }
    }

    private func pop() {
        if case .sessionDetail(self.sessionKey)? = self.navigator.path.last { self.navigator.path.removeLast() }
    }

    private func replace(with key: String) {
        self.pop()
        self.navigator.path.append(.sessionDetail(key))
    }

    private static func branchSubtitle(_ branch: SessionBranch) -> String {
        var parts = ["\(branch.messageCount) \(branch.messageCount == 1 ? "message" : "messages")"]
        if let date = branch.updatedAt { parts.append(date.formatted(.relative(presentation: .named))) }
        if branch.active { parts.append("Active") }
        return parts.joined(separator: " · ")
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let ms = value?.double, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Presents while `value` is set; dismissing clears it (only when set).
    private static func presence<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0, value.wrappedValue != nil { value.wrappedValue = nil } })
    }
}
