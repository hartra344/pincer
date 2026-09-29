import PincerKit
import SwiftUI

/// Gateway Settings → Health: how the Gateway is doing, its channels and connected clients, and a
/// safe restart (`health`, `last-heartbeat`, `system-presence`, `gateway.restart.request`).
struct GatewayHealthPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirmRestart = false
    @State private var confirmForce = false
    @State private var showDismissed = false

    private var model: GatewayHealthModel { self.gateway.health }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Form {
            if Self.showsRestartBanner(model) {
                self.restartBanner(model)
            }
            self.summary(model, connected: connected)
            self.issues(model)
            self.channels(model)
            self.clients(model)
            self.restartSection(model)
        }
        .formStyle(.grouped)
        .navigationTitle(L("Health"))
        .toolbar {
            ToolbarItem {
                Button { Task { await model.load() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(!connected || model.loadState.isRunning)
                    .help(L("Refresh"))
            }
        }
        #if os(iOS)
        .refreshable { if connected { await model.load() } }
        #endif
        .task(id: connected) {
            guard connected else { return }
            await model.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: GatewayHealthModel.refreshInterval)
                guard !Task.isCancelled else { return }
                await model.refreshIfStale()
            }
        }
        .confirmationDialog(L("Restart Gateway?"), isPresented: self.$confirmRestart, titleVisibility: .visible) {
            Button(L("Restart Gateway"), role: .destructive) { Task { await model.restart() } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("Running replies and tasks finish first. Connected clients disconnect briefly.", bundle: .module)
        }
        .confirmationDialog(L("Restart now anyway?"), isPresented: self.$confirmForce, titleVisibility: .visible) {
            Button(L("Restart Now"), role: .destructive) { Task { await model.restart(skipDeferral: true) } }
            Button(L("Keep Waiting"), role: .cancel) {}
        } message: {
            Text("Replies and tasks that are still running are interrupted. Connected clients disconnect briefly.", bundle: .module)
        }
    }

    // MARK: Sections

    private static let dismissFooter = L("Dismissed issues come back if they get worse, or clear up and happen again.")

    @ViewBuilder private func issues(_ model: GatewayHealthModel) -> some View {
        let active = model.activeIssues
        let absent = model.ignoredButAbsent
        let dismissed = model.dismissedIssues + absent
        if !active.isEmpty {
            Section {
                ForEach(active) { issue in
                    GatewayHealthIssueRow(issue: issue, model: model) { self.confirmRestart = true }
                }
            } header: {
                Text("Issues", bundle: .module)
            } footer: {
                Text(Self.dismissFooter)
            }
        }
        if !dismissed.isEmpty {
            Section {
                DisclosureGroup(L("Dismissed (\(dismissed.count))"), isExpanded: self.$showDismissed) {
                    ForEach(dismissed) { issue in
                        GatewayHealthIssueRow(issue: issue, model: model,
                                              dismissedCaption: Self.dismissedCaption(issue, model: model,
                                                                                      absent: absent.contains(issue))) {
                            self.confirmRestart = true
                        }
                    }
                }
            } footer: {
                if active.isEmpty { Text(Self.dismissFooter) }
            }
        }
    }

    static func dismissedCaption(_ issue: GatewayHealthIssue, model: GatewayHealthModel, absent: Bool) -> String {
        if absent { return L("Always ignored · Not reported right now") }
        return model.dismissal(for: issue.id) == .always ? L("Always ignored") : L("Dismissed until it changes")
    }

    static func showsRestartBanner(_ model: GatewayHealthModel) -> Bool {
        model.needsRestart && !model.restartState.isInProgress
    }

    private func restartBanner(_ model: GatewayHealthModel) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Restart needed to apply changes", bundle: .module)
                    if let reason = model.restartRequiredReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("A channel is waiting for a Gateway restart.", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            }
            self.restartButton(model)
        }
    }

    private func summary(_ model: GatewayHealthModel, connected: Bool) -> some View {
        let level = model.level
        return Section {
            LabeledContent(L("Status")) {
                Label(level.label, systemImage: level.symbol).foregroundStyle(Self.color(level))
            }
            if level == .healthy, case let count = model.dismissedIssues.count, count > 0 {
                Text(count == 1 ? L("1 dismissed issue") : L("\(count) dismissed issues")).font(.caption).foregroundStyle(.secondary)
            }
            if let failure = model.healthFailure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
            if let version = model.serverVersion ?? self.gateway.hello?.serverVersion {
                LabeledContent(L("Version"), value: version)
            }
            LabeledContent(L("Uptime")) {
                if connected, let started = model.startedAt {
                    Text(started, style: .relative)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            LabeledContent(L("Last heartbeat")) { self.heartbeat(model) }
            if let error = model.loadState.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
        }
    }

    @ViewBuilder private func heartbeat(_ model: GatewayHealthModel) -> some View {
        if let beat = model.heartbeat {
            if let at = beat.at {
                Text("\(beat.status.label) · \(Text(at, style: .relative)) ago")
                    .foregroundStyle(beat.isFailure ? .red : .primary)
            } else {
                Text(beat.status.label).foregroundStyle(beat.isFailure ? .red : .primary)
            }
        } else if !model.isAvailable(.heartbeat) {
            Text("Unavailable on this Gateway", bundle: .module).foregroundStyle(.secondary)
        } else if model.heartbeatLoaded {
            Text("No heartbeat yet", bundle: .module).foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func channels(_ model: GatewayHealthModel) -> some View {
        Section(L("Channels")) {
            if let health = model.health {
                if health.channels.isEmpty {
                    Text("No channels are set up.", bundle: .module).foregroundStyle(.secondary)
                }
                ForEach(health.channels) { channel in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(channel.label)
                            if let error = channel.lastError {
                                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        ChannelStateBadge(state: ChannelRules.summaryState(of: channel))
                    }
                    .contextMenu {
                        Button(L("Show in Channel Status"), systemImage: "antenna.radiowaves.left.and.right") {
                            self.showInChannelStatus(channel)
                        }
                    }
                }
            } else if !model.isAvailable(.health) {
                Text("Unavailable on this Gateway", bundle: .module).foregroundStyle(.secondary)
            } else {
                Text(model.hasLoaded ? L("No channel details yet.") : L("Loading…")).foregroundStyle(.secondary)
            }
        }
    }

    private func clients(_ model: GatewayHealthModel) -> some View {
        Section(L("Connected Clients")) {
            let entries = model.sortedPresence
            if entries.isEmpty {
                Text(model.isAvailable(.presence) ? L("No clients reported.") : L("Unavailable on this Gateway"))
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(entry.displayName)
                        if model.isThisDevice(entry) {
                            Text("This device", bundle: .module)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.hairline)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    let details = [entry.deviceSummary, entry.roleSummary].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let activity = entry.lastActivityAt {
                        Text("Active \(Text(activity, style: .relative)) ago", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    } else if let since = entry.onlineSince {
                        Text("Online for \(Text(since, style: .relative))", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func restartSection(_ model: GatewayHealthModel) -> some View {
        Section {
            if let message = model.restartState.message {
                HStack(spacing: Theme.Spacing.md) {
                    if model.restartState.isInProgress {
                        ProgressView().controlSize(.small)
                    }
                    self.restartStatus(model, message: message)
                    Spacer()
                    switch model.restartState {
                    case .restarted, .failed:
                        Button(L("Dismiss")) { model.dismissRestartStatus() }.buttonStyle(.borderless)
                    default:
                        EmptyView()
                    }
                }
            }
            // The banner already has the button.
            if !Self.showsRestartBanner(model) {
                self.restartButton(model)
            }
            if model.canForceRestart {
                Button(L("Restart Now Anyway…"), role: .destructive) { self.confirmForce = true }
            }
        } header: {
            Text("Restart", bundle: .module)
        } footer: {
            Text("The Gateway waits for running replies and tasks to finish, then restarts. Pincer reconnects on its own.", bundle: .module)
        }
    }

    @ViewBuilder private func restartStatus(_ model: GatewayHealthModel, message: String) -> some View {
        switch model.restartState {
        case .restarted:
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let started = model.startedAt {
                    Text("Up for \(Text(started, style: .relative))", bundle: .module).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed:
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .notBack:
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        default:
            Text(message).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func restartButton(_ model: GatewayHealthModel) -> some View {
        if !model.isAvailable(.restart) {
            Text("Restarting is unavailable on this Gateway.", bundle: .module).foregroundStyle(.secondary)
        } else if !model.hasAdmin {
            Button {
                self.navigator.destination = .connection
            } label: {
                Label(L("Restarting needs Full Management access"), systemImage: "lock")
            }
            .help(L("Open Connection to turn on Full Management."))
        } else {
            Button(L("Restart Gateway…"), systemImage: "arrow.clockwise") { self.confirmRestart = true }
                .disabled(!model.canRestart)
        }
    }

    // MARK: Colors

    static func color(_ level: GatewayHealthLevel) -> Color {
        switch level {
        case .healthy: .green
        case .degraded: .orange
        case .down: .red
        case .restarting: .blue
        }
    }

    private func showInChannelStatus(_ channel: GatewayChannelHealth) {
        if let account = channel.effectiveAccounts.first {
            self.gateway.channels.focusedAccount = ChannelAccountKey(channel: channel.id, accountId: account.accountId)
        }
        self.navigator.destination = .channelStatus
    }

    static func color(_ status: GatewayChannelHealth.Status) -> Color {
        switch status {
        case .connected, .running: .green
        case .stopped: .orange
        case .error: .red
        case .disabled, .notConfigured, .unknown: .secondary
        }
    }
}

/// One Health issue: Dismiss or Always Ignore when active, Restore when dismissed, from the context
/// menu, a swipe (iOS), a hover button (macOS) or accessibility actions.
private struct GatewayHealthIssueRow: View {
    let issue: GatewayHealthIssue
    let model: GatewayHealthModel
    /// Set for rows in the Dismissed section.
    var dismissedCaption: String?
    let onRestart: () -> Void
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var hovering = false
    @State private var qrAccount: ChannelAccountKey?

    private var channels: ChannelsModel { self.gateway.channels }

    /// A logged-out QR channel account (e.g. WhatsApp): Reconnect can't help, linking can.
    private func needsQRLogin(_ key: ChannelAccountKey) -> Bool {
        guard self.channels.offersQRLogin(key) else { return false }
        let state: ChannelAccountState? = self.channels.snapshot?.state(of: key)
            ?? self.model.health.map { ChannelsStatusSnapshot(health: $0) }?.state(of: key)
        return state == .loggedOut || state == .notConfigured
    }

    private var isDismissed: Bool { self.dismissedCaption != nil }

    private var alwaysIgnoreTitle: String {
        self.issue.kind == .channel ? L("Always Ignore This Account") : L("Always Ignore This Plugin")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(self.issue.title)
                    if let caption = self.dismissedCaption {
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    } else if let detail = self.issue.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let key = self.issue.channelAccount, let operation = self.channels.operation(for: key) {
                        if operation.state.isRunning {
                            Text(operation.action == .reconnect ? L("Reconnecting…") : L("Working…"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let failure = operation.state.error {
                            Text("Couldn't \(operation.action == .logout ? L("log out") : operation.action.title.lowercased()): \(failure)", bundle: .module).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            } icon: {
                Image(systemName: self.issue.symbol).foregroundStyle(self.isDismissed ? Color.secondary : Color.orange)
            }
            #if os(macOS)
            Spacer(minLength: 8)
            self.hoverButton
                .opacity(self.hovering ? 1 : 0)
                .allowsHitTesting(self.hovering)
                .accessibilityHidden(true)
            #endif
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { self.hovering = $0 }
        #endif
        .contextMenu { self.menu }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            if !self.isDismissed, let key = self.issue.channelAccount, self.channels.canManage {
                if self.needsQRLogin(key) {
                    Button(L("Link with QR Code…"), systemImage: "qrcode") { self.qrAccount = key }
                        .tint(.blue)
                        .disabled(self.channels.isBusy(key) || !self.gateway.state.isConnected)
                } else if let reconnect = self.reconnectAction {
                    Button(L("Reconnect Account"), systemImage: ChannelsModel.Action.reconnect.symbol, action: reconnect)
                        .tint(.blue)
                        .disabled(self.channels.isBusy(key) || !self.gateway.state.isConnected)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if self.isDismissed {
                Button(L("Restore"), systemImage: "arrow.uturn.backward") { self.model.restore(id: self.issue.id) }
                    .tint(.blue)
            } else {
                Button(L("Dismiss"), systemImage: "eye.slash") { self.model.dismiss(self.issue) }
                    .tint(.gray)
            }
        }
        #endif
        .accessibilityElement(children: .combine)
        .modifier(IssueAccessibilityActions(issue: self.issue, model: self.model, isDismissed: self.isDismissed,
                                            alwaysIgnoreTitle: self.alwaysIgnoreTitle))
        .modifier(ReconnectAccessibilityAction(reconnect: self.reconnectAction, linkWithQR: self.linkAction))
        .sheet(item: self.$qrAccount) { key in
            ChannelQRLoginSheet(model: self.channels, key: key, channelLabel: self.channels.label(for: key))
        }
    }

    @ViewBuilder private var menu: some View {
        if self.isDismissed {
            Button(L("Restore"), systemImage: "arrow.uturn.backward") { self.model.restore(id: self.issue.id) }
        } else {
            Button(L("Dismiss"), systemImage: "eye.slash") { self.model.dismiss(self.issue) }
            if self.issue.canAlwaysIgnore {
                Button(self.alwaysIgnoreTitle, systemImage: "eye.slash.circle") { self.model.dismiss(self.issue, always: true) }
            }
            if let key = self.issue.channelAccount {
                Divider()
                self.channelItems(key)
            }
            if self.issue.offersRestart, self.model.canRestart {
                Divider()
                Button(L("Restart Gateway…"), systemImage: "arrow.clockwise") { self.onRestart() }
            }
        }
    }

    /// Reconnect Account (`channels.stop` then `channels.start`) and Show in Channel Status. Reconnecting
    /// refreshes `health`, so the issue clears once the account is back.
    @ViewBuilder private func channelItems(_ key: ChannelAccountKey) -> some View {
        let channels = self.channels
        if self.needsQRLogin(key) {
            if channels.canManage {
                Button(L("Link with QR Code…"), systemImage: "qrcode") { self.qrAccount = key }
                    .disabled(channels.isBusy(key) || !self.gateway.state.isConnected)
            } else {
                Button(L("Link with QR Code (\(SetupWizardModel.fullManagementTitle))"), systemImage: "lock") {}
                    .disabled(true)
            }
        } else if channels.supports(.reconnect) {
            if channels.canManage {
                Button(L("Reconnect Account"), systemImage: ChannelsModel.Action.reconnect.symbol) {
                    Task { await channels.reconnect(key) }
                }
                .disabled(channels.isBusy(key) || !self.gateway.state.isConnected)
            } else {
                Button(L("Reconnect Account (\(SetupWizardModel.fullManagementTitle))"), systemImage: "lock") {}
                    .disabled(true)
            }
        }
        Button(L("Show in Channel Status"), systemImage: "antenna.radiowaves.left.and.right") {
            channels.focusedAccount = key
            self.navigator.destination = .channelStatus
        }
    }

    #if os(macOS)
    @ViewBuilder private var hoverButton: some View {
        if self.isDismissed {
            Button(L("Restore")) { self.model.restore(id: self.issue.id) }
                .buttonStyle(.borderless)
                .help(L("Show this issue again"))
        } else {
            Button(L("Dismiss")) { self.model.dismiss(self.issue) }
                .buttonStyle(.borderless)
                .help(L("Dismiss until it changes"))
        }
    }
    #endif
}

extension GatewayHealthIssueRow {
    /// The accessibility Reconnect Account action, when this is an active channel issue it can reconnect.
    fileprivate var reconnectAction: (() -> Void)? {
        guard !self.isDismissed, let key = self.issue.channelAccount, self.channels.supports(.reconnect),
              self.channels.canManage, self.gateway.state.isConnected, !self.needsQRLogin(key) else { return nil }
        let channels = self.channels
        return { Task { await channels.reconnect(key) } }
    }

    /// The accessibility Link with QR Code action, for a logged-out QR channel account.
    fileprivate var linkAction: (() -> Void)? {
        guard !self.isDismissed, let key = self.issue.channelAccount, self.channels.canManage,
              self.gateway.state.isConnected, self.needsQRLogin(key) else { return nil }
        return { self.qrAccount = key }
    }
}

private struct ReconnectAccessibilityAction: ViewModifier {
    let reconnect: (() -> Void)?
    let linkWithQR: (() -> Void)?

    func body(content: Content) -> some View {
        if let linkWithQR = self.linkWithQR {
            content.accessibilityAction(named: L("Link with QR Code"), linkWithQR)
        } else if let reconnect = self.reconnect {
            content.accessibilityAction(named: L("Reconnect Account"), reconnect)
        } else {
            content
        }
    }
}

private struct IssueAccessibilityActions: ViewModifier {
    let issue: GatewayHealthIssue
    let model: GatewayHealthModel
    let isDismissed: Bool
    let alwaysIgnoreTitle: String

    func body(content: Content) -> some View {
        if self.isDismissed {
            content.accessibilityAction(named: L("Restore")) { self.model.restore(id: self.issue.id) }
        } else if self.issue.canAlwaysIgnore {
            content
                .accessibilityAction(named: L("Dismiss")) { self.model.dismiss(self.issue) }
                .accessibilityAction(named: self.alwaysIgnoreTitle) { self.model.dismiss(self.issue, always: true) }
        } else {
            content.accessibilityAction(named: L("Dismiss")) { self.model.dismiss(self.issue) }
        }
    }
}

/// The compact health line under a gateway in the sidebar; opens Gateway Settings → Health.
struct GatewayHealthIndicatorRow: View {
    let indicator: GatewayHealthModel.Indicator
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.openGatewaySettings) private var openGatewaySettings

    var body: some View {
        Button {
            self.openGatewaySettings(self.gateway, at: .health)
        } label: {
            Label(self.indicator.message, systemImage: self.symbol)
                .foregroundStyle(self.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Open Gateway Health"))
    }

    private var symbol: String {
        switch self.indicator {
        case .degraded: "exclamationmark.triangle"
        case .restartNeeded: "arrow.clockwise.circle"
        case .restarting, .reconnecting: "arrow.triangle.2.circlepath"
        case .notBack: "exclamationmark.circle"
        }
    }

    private var color: Color {
        switch self.indicator {
        case .degraded, .restartNeeded, .notBack: .orange
        case .restarting, .reconnecting: .secondary
        }
    }
}
