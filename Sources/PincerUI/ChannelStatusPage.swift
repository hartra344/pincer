import PincerKit
import SwiftUI

/// Gateway Settings → Channel Status: every channel account's connection from `channels.status`, with
/// Probe, Start, Stop, Log Out, Reconnect and QR login (lifecycle needs Full Management). Upstream has
/// no channel status event, so the page loads when it opens, on `health` events and every 30 seconds
/// while it's showing, on Refresh or pull to refresh, and after each action.
struct ChannelStatusPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirming: PendingAction?
    @State private var qrAccount: ChannelAccountKey?

    struct PendingAction: Identifiable {
        let action: ChannelsModel.Action
        let key: ChannelAccountKey
        let label: String
        /// As the row shows it: "Default", or the account's name.
        let accountName: String
        var id: String { "\(self.action.rawValue):\(self.key.id)" }
    }

    private var model: ChannelsModel { self.gateway.channels }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if connected, model.hasLoaded, !model.supported {
                self.unsupported
            } else if !connected, model.snapshot == nil {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Not connected to the Gateway."))
            } else {
                self.list(model, connected: connected)
            }
        }
        .navigationTitle("Channel Status")
        .toolbar {
            if connected, model.supported {
                ToolbarItem {
                    Button { Task { await model.probe() } } label: {
                        Label(model.isProbing ? "Probing…" : "Probe", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(model.loadState.isRunning)
                    .help("Probe: ask each channel to check its connection now")
                }
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.loadState.isRunning)
                        .help("Refresh")
                }
            }
        }
        .refreshable { if self.gateway.state.isConnected { await model.refresh() } }
        .task(id: connected) {
            guard connected else { return }
            await model.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: ChannelsModel.refreshInterval)
                guard !Task.isCancelled, self.gateway.state.isConnected else { return }
                await model.poll()
            }
        }
        .onAppear { model.isShowing = true }
        .onDisappear {
            model.isShowing = false
            model.focusedAccount = nil
        }
        .confirmationDialog(self.confirming.map(Self.confirmTitle) ?? "", isPresented: Binding(
            get: { self.confirming != nil },
            set: { if !$0 { self.confirming = nil } }
        ), titleVisibility: .visible, presenting: self.confirming) { pending in
            Button(pending.action == .logout ? "Log Out" : pending.action.title, role: .destructive) {
                Task { await model.perform(pending.action, on: pending.key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(Self.confirmMessage(pending))
        }
        .sheet(item: self.$qrAccount) { key in
            ChannelQRLoginSheet(model: model, key: key, channelLabel: model.label(for: key))
        }
        .overlay(alignment: .bottom) { self.noticeView(model) }
    }

    /// "Stop Telegram (default)?" / "Log out of WhatsApp (default)?"
    static func confirmTitle(_ pending: PendingAction) -> String {
        let name = "\(pending.label) (\(pending.accountName))"
        return pending.action == .logout ? "Log out of \(name)?" : "\(pending.action.title) \(name)?"
    }

    static func confirmMessage(_ pending: PendingAction) -> String {
        switch pending.action {
        case .logout:
            ChannelRules.supportsQRLogin(pending.key.channel)
                ? "This removes the saved login. You'll need to scan a QR code again to reconnect."
                : "This removes the saved login. You'll need to set it up again to reconnect."
        default:
            "Pincer stops this account until you start it again or the Gateway restarts. Messages to it won't be answered."
        }
    }

    // MARK: List

    private func list(_ model: ChannelsModel, connected: Bool) -> some View {
        ScrollViewReader { proxy in
            Form {
                if !connected {
                    Section {
                        Label("Not connected to the Gateway", systemImage: "bolt.horizontal.circle")
                            .foregroundStyle(.secondary)
                    }
                } else if !model.canManage {
                    Section { FullManagementBadge { self.navigator.destination = .connection } }
                }
                if connected, let error = model.loadState.error {
                    Section {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            Spacer()
                            Button("Retry") { Task { await model.refresh() } }
                        }
                    }
                }
                if let snapshot = model.snapshot {
                    if snapshot.channels.isEmpty {
                        Section { self.noChannels }
                    }
                    Group {
                        ForEach(snapshot.channels) { channel in
                            self.channelSection(channel, snapshot: snapshot, model: model,
                                                readOnly: !connected || !model.canManage)
                        }
                    }
                    .opacity(connected ? 1 : 0.5)
                    .disabled(!connected)
                    self.footerSection(snapshot, model: model)
                } else if model.loadState.isRunning || !model.hasLoaded {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.snapshot != nil, initial: true) { self.scrollToFocus(proxy) }
            .onChange(of: model.focusedAccount) { self.scrollToFocus(proxy) }
        }
    }

    private var noChannels: some View {
        ContentUnavailableView {
            Label("No Channels", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("This Gateway has no channel accounts. Pincer talks to your agents directly, so you don't need any.")
        } actions: {
            Button("Open Channels Settings") { self.navigator.destination = .page("channels") }
        }
    }

    /// No `channels.status`: say so, and show Health's channel list read-only if there is one.
    @ViewBuilder private var unsupported: some View {
        if let health = self.gateway.health.health, !health.channels.isEmpty {
            let snapshot = ChannelsStatusSnapshot(health: health)
            Form {
                Section {
                    Label("Unavailable on this Gateway", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("This Gateway doesn't report channel status, so these are the channels from Health, read-only.")
                }
                ForEach(snapshot.channels) { channel in
                    self.channelSection(channel, snapshot: snapshot, model: self.model, readOnly: true)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Unavailable on this Gateway", systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text("This Gateway doesn't report channel status. Update OpenClaw to see it here."))
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let key = self.model.focusedAccount, self.model.snapshot != nil else { return }
        withAnimation { proxy.scrollTo(key.id, anchor: .center) }
    }

    private func channelSection(_ channel: GatewayChannelHealth, snapshot: ChannelsStatusSnapshot,
                                model: ChannelsModel, readOnly: Bool) -> some View {
        Section {
            ForEach(channel.effectiveAccounts) { account in
                let key = ChannelAccountKey(channel: channel.id, accountId: account.accountId)
                ChannelAccountRow(key: key, channel: channel, account: account,
                                  issues: snapshot.issues(for: key), model: model, readOnly: readOnly,
                                  confirm: {
                                      self.confirming = PendingAction(action: $0, key: key, label: channel.label,
                                                                      accountName: ChannelAccountRow.displayName(key, account))
                                  },
                                  logIn: { self.qrAccount = key })
                    .id(key.id)
                    .listRowBackground(model.focusedAccount == key ? Color.accentColor.opacity(0.12) : nil)
            }
        } header: {
            if let detail = snapshot.detailLabels[channel.id], detail != channel.label {
                Text("\(channel.label) · \(detail)")
            } else {
                Text(channel.label)
            }
        }
    }

    @ViewBuilder private func footerSection(_ snapshot: ChannelsStatusSnapshot, model: ChannelsModel) -> some View {
        Section {
            if model.isProbing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Probing channels…").foregroundStyle(.secondary)
                }
            }
            if snapshot.partial {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Some channels didn't answer in time.", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    ForEach(snapshot.warnings.prefix(5), id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let checked = snapshot.checkedAt {
                Text("Checked \(Text(checked, style: .relative)) ago").font(.caption).foregroundStyle(.secondary)
            }
            Button("Approving new senders? See Pairing Requests.") { self.navigator.destination = .pairing }
                .buttonStyle(.borderless)
                .font(.callout)
        } footer: {
            Text("Probe asks each channel to check its connection now. Reconnect stops the account, then starts it again.")
        }
    }

    @ViewBuilder private func noticeView(_ model: ChannelsModel) -> some View {
        if let notice = model.notice {
            Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.red : Color.green)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule())
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation { model.clearNotice() } }
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, model.notice?.id == notice.id else { return }
                    withAnimation { model.clearNotice() }
                }
        }
    }

    /// Badge colors, shared with Gateway Health's channel list. Badges always have a text label too.
    static func color(_ state: ChannelAccountState) -> Color {
        switch state {
        case .connected, .running: .green
        case .degraded, .disconnected: .orange
        case .loggedOut: .yellow
        case .stopped: .gray
        case .notConfigured, .disabled, .unknown: .secondary
        }
    }
}

/// The status badge: symbol, label and color, used on Channel Status and Gateway Health.
struct ChannelStateBadge: View {
    let state: ChannelAccountState

    var body: some View {
        Label(self.state.label, systemImage: self.state.symbol)
            .font(.callout)
            .foregroundStyle(ChannelStatusPage.color(self.state))
            .accessibilityLabel("Status: \(self.state.label)")
    }
}

/// One channel account: its badge, error and status issues, when it last did something, and its actions.
private struct ChannelAccountRow: View {
    let key: ChannelAccountKey
    let channel: GatewayChannelHealth
    let account: GatewayChannelAccountHealth
    let issues: [ChannelsStatusSnapshot.Issue]
    let model: ChannelsModel
    /// Offline, without Full Management, or Health's list on a Gateway without `channels.status`.
    let readOnly: Bool
    let confirm: (ChannelsModel.Action) -> Void
    let logIn: () -> Void
    @State private var errorExpanded = false

    static func displayName(_ key: ChannelAccountKey, _ account: GatewayChannelAccountHealth) -> String {
        key.accountId == "default" ? "Default" : account.name ?? key.accountId
    }

    private var name: String { Self.displayName(self.key, self.account) }

    var body: some View {
        let state = ChannelRules.state(of: self.account, issues: self.issues)
        let operation = self.model.operation(for: self.key)
        let managing = !self.readOnly && self.model.canManage
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.name)
                    if self.key.accountId != "default", let name = self.account.name, name != self.key.accountId {
                        Text(self.key.accountId).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let operation, operation.state.isRunning {
                    ProgressView().controlSize(.small)
                    Text(Self.progressText(operation.action)).font(.caption).foregroundStyle(.secondary)
                }
                ChannelStateBadge(state: state)
                if managing, self.hasAnyAction {
                    self.actionsMenu
                }
            }
            if let error = self.account.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(self.errorExpanded ? nil : 2)
                    .textSelection(.enabled)
                    .help(error)
                    .onTapGesture { self.errorExpanded.toggle() }
            }
            ForEach(self.issues, id: \.self) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.message).font(.caption)
                    if let fix = issue.fix { Text(fix).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            self.times(state)
            if let operation, let failure = operation.state.error {
                Text("Couldn't \(operation.action.verbText): \(failure)").font(.caption).foregroundStyle(.red)
            }
            if managing, self.needsLogIn(state) {
                Button(action: self.logIn) { Label("Link with QR Code…", systemImage: "qrcode") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!self.model.canLogIn(self.key) || self.model.isBusy(self.key))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { if managing { self.menuItems(state) } }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if managing {
                if self.model.offers(.stop, on: self.key) {
                    Button("Stop…", systemImage: ChannelsModel.Action.stop.symbol) { self.confirm(.stop) }
                        .tint(.gray)
                        .disabled(!self.model.canPerform(.stop, on: self.key))
                }
                if self.model.offers(.reconnect, on: self.key) {
                    Button("Reconnect", systemImage: ChannelsModel.Action.reconnect.symbol) { self.run(.reconnect) }
                        .tint(.blue)
                        .disabled(!self.model.canPerform(.reconnect, on: self.key))
                }
            }
        }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityActions { if managing { self.accessibilityItems(state) } }
    }

    private func needsLogIn(_ state: ChannelAccountState) -> Bool {
        self.model.offersQRLogin(self.key) && (state == .loggedOut || state == .notConfigured)
    }

    static func progressText(_ action: ChannelsModel.Action) -> String {
        switch action {
        case .start: "Starting…"
        case .stop: "Stopping…"
        case .logout: "Logging out…"
        case .reconnect: "Reconnecting…"
        }
    }

    @ViewBuilder private func times(_ state: ChannelAccountState) -> some View {
        HStack(spacing: 10) {
            if let activity = self.account.lastActivityAt {
                Text("Last message \(Text(activity, style: .relative)) ago")
            } else if state != .disabled, state != .notConfigured {
                Text("No activity yet")
            }
            if state == .connected, let since = self.account.lastConnectedAt {
                Text("Connected since \(since.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
            }
            if let probed = self.account.lastProbeAt {
                Text("Probed \(Text(probed, style: .relative)) ago")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if let attempts = self.account.reconnectAttempts, attempts > 0 {
            Text("\(attempts) reconnect attempt\(attempts == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actionsMenu: some View {
        let state = ChannelRules.state(of: self.account, issues: self.issues)
        return Menu {
            self.menuItems(state)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        #if os(macOS)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .help("Actions for \(self.model.label(for: self.key))")
    }

    private var hasAnyAction: Bool {
        ChannelsModel.Action.allCases.contains { self.model.offers($0, on: self.key) } || self.model.offersQRLogin(self.key)
    }

    private func run(_ action: ChannelsModel.Action) {
        let model = self.model
        let key = self.key
        Task { await model.perform(action, on: key) }
    }

    /// Stop and Log Out ask first; Reconnect and Start don't.
    private func trigger(_ action: ChannelsModel.Action) {
        switch action {
        case .stop, .logout: self.confirm(action)
        case .start, .reconnect: self.run(action)
        }
    }

    private static func menuTitle(_ action: ChannelsModel.Action) -> String {
        switch action {
        case .stop: "Stop…"
        case .logout: "Log Out…"
        default: action.title
        }
    }

    @ViewBuilder private func menuItems(_ state: ChannelAccountState) -> some View {
        ForEach([ChannelsModel.Action.reconnect, .start, .stop], id: \.self) { action in
            if self.model.offers(action, on: self.key) {
                Button(Self.menuTitle(action), systemImage: action.symbol) { self.trigger(action) }
                    .disabled(!self.model.canPerform(action, on: self.key))
            }
        }
        if self.model.offersQRLogin(self.key) {
            let linked = !self.needsLogIn(state)
            Button(linked ? "Relink with QR Code…" : "Link with QR Code…", systemImage: "qrcode", action: self.logIn)
                .disabled(!self.model.canLogIn(self.key) || self.model.isBusy(self.key))
        }
        if self.model.offers(.logout, on: self.key) {
            Divider()
            Button("Log Out…", systemImage: ChannelsModel.Action.logout.symbol, role: .destructive) { self.confirm(.logout) }
                .disabled(!self.model.canPerform(.logout, on: self.key))
        }
    }

    @ViewBuilder private func accessibilityItems(_ state: ChannelAccountState) -> some View {
        ForEach(ChannelsModel.Action.allCases, id: \.self) { action in
            if self.model.canPerform(action, on: self.key) {
                Button(Self.menuTitle(action)) { self.trigger(action) }
            }
        }
        if self.model.canLogIn(self.key), !self.model.isBusy(self.key) {
            Button(self.needsLogIn(state) ? "Link with QR Code…" : "Relink with QR Code…", action: self.logIn)
        }
    }
}

/// QR login for one account, in a sheet: starts on open, closes itself a moment after linking, and
/// stops waiting when closed. Used by Channel Status and Gateway Health.
struct ChannelQRLoginSheet: View {
    let model: ChannelsModel
    let key: ChannelAccountKey
    let channelLabel: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = self.model.qr.state(channel: self.key.channel, accountId: self.key.accountId)
        let linked = self.model.state(of: self.key).isHealthy
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ChannelQRLoginView(state: state, channelLabel: self.channelLabel, linked: linked,
                                   canStart: self.model.canLogIn(self.key),
                                   offersRelinkWhenLinked: false,
                                   start: { self.model.startQRLogin(self.key, force: $0) },
                                   cancel: {
                                       self.model.cancelQRLogin(self.key)
                                       self.dismiss()
                                   })
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Link \(self.channelLabel)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.isConnected ? "Done" : "Cancel") { self.dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 360)
        #else
        .presentationDetents([.large])
        #endif
        .task {
            if !state.isRunning {
                self.model.startQRLogin(self.key, force: linked || state.isConnected)
            }
        }
        .task(id: state.isConnected) {
            guard state.isConnected else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
        .onDisappear {
            if self.model.qr.state(channel: self.key.channel, accountId: self.key.accountId).isRunning {
                self.model.cancelQRLogin(self.key)
            }
        }
    }
}

private extension ChannelQRLoginState {
    var isConnected: Bool { if case .connected = self { true } else { false } }
}

private extension ChannelsModel.Action {
    /// "Couldn't reconnect: …"
    var verbText: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .logout: "log out"
        case .reconnect: "reconnect"
        }
    }
}
