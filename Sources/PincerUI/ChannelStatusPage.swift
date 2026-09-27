import PincerKit
import SwiftUI

/// Gateway Settings → Channel Status: every channel account's connection from `channels.status`, with
/// Probe, Start, Stop, Log Out, Reconnect and QR login (lifecycle needs Full Management). Upstream has
/// no channel status event, so the page loads when it opens, every 30 seconds while it's showing, on
/// pull to refresh, and after each action.
struct ChannelStatusPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirming: PendingAction?

    struct PendingAction: Identifiable {
        let action: ChannelsModel.Action
        let key: ChannelAccountKey
        let label: String
        var id: String { "\(self.action.rawValue):\(self.key.id)" }
    }

    private var model: ChannelsModel { self.gateway.channels }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if !connected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see its channels."))
            } else if !model.supported {
                ContentUnavailableView("Channel Status Isn't Available", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("This Gateway doesn't report channel status. Update OpenClaw to see it here."))
            } else {
                self.list(model)
            }
        }
        .navigationTitle("Channel Status")
        .toolbar {
            if connected, model.supported {
                ToolbarItem {
                    Button { Task { await model.probe() } } label: {
                        Label("Probe", systemImage: "antenna.radiowaves.left.and.right")
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
        .onDisappear { model.focusedAccount = nil }
        .confirmationDialog(self.confirming.map(Self.confirmTitle) ?? "", isPresented: Binding(
            get: { self.confirming != nil },
            set: { if !$0 { self.confirming = nil } }
        ), titleVisibility: .visible, presenting: self.confirming) { pending in
            Button(pending.action.title, role: .destructive) {
                Task { await model.perform(pending.action, on: pending.key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(Self.confirmMessage(pending))
        }
        .overlay(alignment: .bottom) { self.noticeView(model) }
    }

    static func confirmTitle(_ pending: PendingAction) -> String {
        pending.action == .logout ? "Log out of \(pending.label)?" : "\(pending.action.title) \(pending.label)?"
    }

    static func confirmMessage(_ pending: PendingAction) -> String {
        switch pending.action {
        case .logout:
            ChannelRules.supportsQRLogin(pending.key.channel)
                ? "This removes its saved login from the Gateway. To use it again, scan a new QR code."
                : "This removes its saved login from the Gateway. You'll need to set it up again to use it."
        default:
            "It stops sending and receiving messages until you start it again."
        }
    }

    // MARK: List

    private func list(_ model: ChannelsModel) -> some View {
        ScrollViewReader { proxy in
            Form {
                if !model.canManage {
                    Section { self.fullManagementNotice }
                }
                if let error = model.loadState.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                if let snapshot = model.snapshot {
                    if snapshot.channels.isEmpty {
                        Section {
                            Text("No channels are set up. Add one in Gateway Settings → Channels.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(snapshot.channels) { channel in
                        self.channelSection(channel, snapshot: snapshot, model: model)
                    }
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

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let key = self.model.focusedAccount, self.model.snapshot != nil else { return }
        withAnimation { proxy.scrollTo(key.id, anchor: .center) }
    }

    private func channelSection(_ channel: GatewayChannelHealth, snapshot: ChannelsStatusSnapshot,
                                model: ChannelsModel) -> some View {
        Section {
            ForEach(channel.effectiveAccounts) { account in
                let key = ChannelAccountKey(channel: channel.id, accountId: account.accountId)
                ChannelAccountRow(key: key, channel: channel, account: account,
                                  issues: snapshot.issues(for: key), model: model,
                                  showsName: channel.effectiveAccounts.count > 1 || account.accountId != "default",
                                  confirm: { self.confirming = PendingAction(action: $0, key: key, label: model.label(for: key)) })
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
        } footer: {
            Text("Probe asks each channel to check its connection now. Reconnect stops the account, then starts it again.")
        }
    }

    private var fullManagementNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(SetupWizardModel.fullManagementTitle, systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
            Text(SetupWizardModel.fullManagementMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Connection…") { self.navigator.destination = .connection }
                .buttonStyle(.borderless)
                .font(.callout)
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

    static func color(_ state: ChannelAccountState) -> Color {
        switch state {
        case .connected, .running: .green
        case .degraded, .disconnected, .stopped: .orange
        case .loggedOut: .red
        case .notConfigured, .disabled, .unknown: .secondary
        }
    }
}

/// One channel account: its badge, error and status issues, when it last did something, and its actions.
private struct ChannelAccountRow: View {
    let key: ChannelAccountKey
    let channel: GatewayChannelHealth
    let account: GatewayChannelAccountHealth
    let issues: [ChannelsStatusSnapshot.Issue]
    let model: ChannelsModel
    let showsName: Bool
    let confirm: (ChannelsModel.Action) -> Void

    var body: some View {
        let state = ChannelRules.state(of: self.account, issues: self.issues)
        let operation = self.model.operation(for: self.key)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.showsName ? (self.account.name ?? self.account.accountId) : self.channel.label)
                    if self.showsName, self.account.name != nil, self.account.name != self.account.accountId {
                        Text(self.account.accountId).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if operation?.state.isRunning == true {
                    ProgressView().controlSize(.small)
                }
                Label(state.label, systemImage: state.symbol)
                    .font(.callout)
                    .foregroundStyle(ChannelStatusPage.color(state))
                    .accessibilityLabel("Status: \(state.label)")
                self.actionsMenu(state)
            }
            if let error = self.account.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            ForEach(self.issues, id: \.self) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.message).font(.caption)
                    if let fix = issue.fix { Text(fix).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            self.times
            if let operation, let failure = operation.state.error {
                Text("\(operation.action.title) failed: \(failure)").font(.caption).foregroundStyle(.red)
            }
            if self.model.offersQRLogin(self.key) {
                ChannelQRLoginView(state: self.model.qr.state(channel: self.key.channel, accountId: self.key.accountId),
                                   channelLabel: self.channel.label,
                                   linked: self.account.linked == true || state.isHealthy,
                                   canStart: self.model.canLogIn(self.key) && operation?.state.isRunning != true,
                                   linkTitle: "Log In with QR Code…",
                                   start: { self.model.startQRLogin(self.key, force: $0) },
                                   cancel: { self.model.cancelQRLogin(self.key) })
            }
        }
        .padding(.vertical, 2)
        .contextMenu { self.menuItems(state) }
    }

    @ViewBuilder private var times: some View {
        let parts = [
            self.account.lastActivityAt.map { ("Last activity", $0) },
            self.account.lastActivityAt == nil ? self.account.lastConnectedAt.map { ("Connected", $0) } : nil,
            self.account.lastProbeAt.map { ("Probed", $0) },
        ].compactMap(\.self)
        if !parts.isEmpty {
            HStack(spacing: 10) {
                ForEach(parts, id: \.0) { part in
                    Text("\(part.0) \(Text(part.1, style: .relative)) ago")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let attempts = self.account.reconnectAttempts, attempts > 0 {
            Text("\(attempts) reconnect attempt\(attempts == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func actionsMenu(_ state: ChannelAccountState) -> some View {
        Menu {
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
        .disabled(!self.hasAnyAction(state))
    }

    private func hasAnyAction(_ state: ChannelAccountState) -> Bool {
        ChannelsModel.Action.allCases.contains { self.model.offers($0, on: self.key) }
    }

    @ViewBuilder private func menuItems(_ state: ChannelAccountState) -> some View {
        let model = self.model
        let key = self.key
        if !model.canManage {
            Text(SetupWizardModel.fullManagementTitle)
        }
        if model.offers(.reconnect, on: key) {
            Button(ChannelsModel.Action.reconnect.title, systemImage: ChannelsModel.Action.reconnect.symbol) {
                Task { await model.reconnect(key) }
            }
            .disabled(!model.canPerform(.reconnect, on: key))
        }
        if model.offers(.start, on: key) {
            Button(ChannelsModel.Action.start.title, systemImage: ChannelsModel.Action.start.symbol) {
                Task { await model.start(key) }
            }
            .disabled(!model.canPerform(.start, on: key))
        }
        if model.offers(.stop, on: key) {
            Button("Stop…", systemImage: ChannelsModel.Action.stop.symbol) { self.confirm(.stop) }
                .disabled(!model.canPerform(.stop, on: key))
        }
        if model.offers(.logout, on: key) {
            Divider()
            Button("Log Out…", systemImage: ChannelsModel.Action.logout.symbol, role: .destructive) { self.confirm(.logout) }
                .disabled(!model.canPerform(.logout, on: key))
        }
    }
}
