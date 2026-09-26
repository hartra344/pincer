import PincerKit
import SwiftUI

/// Gateway Settings → Pairing Requests: senders waiting to DM the agents on a channel account
/// with `dmPolicy: "pairing"` (`channels.pairing.*`). There's no event for new requests, so the
/// page refreshes when it opens, on reconnect and every 30 seconds while it's showing.
struct PairingRequestsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var approving: PairingRequest?

    private var model: PairingInboxModel { self.gateway.pairingInbox }

    var body: some View {
        @Bindable var model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if !connected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to review pairing requests."))
            } else if !model.supported {
                ContentUnavailableView("Pairing Requests Aren't Available", systemImage: "person.badge.key",
                                       description: Text("This Gateway doesn't support channel pairing requests. Update OpenClaw to review them here."))
            } else if model.needsAccess {
                self.accessNeeded
            } else {
                self.list(model)
            }
        }
        .navigationTitle("Pairing Requests")
        .toolbar {
            if connected, model.supported, !model.needsAccess {
                if model.showsChannelFilter {
                    ToolbarItem {
                        Picker("Channel", selection: $model.channelFilter) {
                            Text("All Channels").tag(String?.none)
                            ForEach(model.channels, id: \.id) { channel in
                                Text(channel.label).tag(Optional(channel.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.loadState.isRunning)
                        .help("Refresh")
                }
            }
        }
        .task(id: connected) {
            guard connected else { return }
            await model.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: PairingInboxModel.pollInterval)
                guard !Task.isCancelled, self.gateway.state.isConnected else { return }
                await model.poll()
            }
        }
        .sheet(item: self.$approving) { request in
            ApprovePairingSheet(request: request, model: model)
        }
        .overlay(alignment: .bottom) { self.noticeView(model) }
    }

    // MARK: States

    private var accessNeeded: some View {
        ContentUnavailableView {
            Label("Full Management Needed", systemImage: "lock")
        } description: {
            Text(PairingInboxModel.missingScopeMessage)
        } actions: {
            if self.gateway.profile.access == .admin, !self.gateway.settings.canEdit {
                Text("The Gateway hasn't granted Full Management to this device yet.")
                    .foregroundStyle(.orange)
                ApprovalInstructions(requestId: nil)
                    .frame(maxWidth: 420)
            }
            Button("Open Connection") { self.navigator.destination = .connection }
        }
    }

    private func list(_ model: PairingInboxModel) -> some View {
        let visible = model.visibleRequests
        let groups = Self.groups(visible)
        return List {
            if let error = model.loadState.error, model.hasLoaded, !model.accounts.isEmpty || !model.requests.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    Button("Try Again") { Task { await model.refresh() } }
                }
            }
            if groups.count > 1 {
                ForEach(groups, id: \.channel) { group in
                    Section {
                        self.rows(group.requests, model: model)
                    } header: {
                        Text(group.label)
                    } footer: {
                        if group.channel == groups.last?.channel { self.dismissFooter }
                    }
                }
            } else if !visible.isEmpty {
                Section {
                    self.rows(visible, model: model)
                } footer: {
                    self.dismissFooter
                }
            } else if model.hasLoaded, !model.accounts.isEmpty {
                self.noRequests(model)
            }
        }
        #if os(iOS)
        .refreshable { await model.refresh() }
        #endif
        .overlay { self.state(model) }
    }

    /// On macOS this is the Dismiss button's tooltip.
    @ViewBuilder private var dismissFooter: some View {
        #if os(iOS)
        Text(Self.dismissHelp)
        #endif
    }

    static let dismissHelp = "Dismiss removes a request. The sender isn't blocked and can ask again."

    private func rows(_ requests: [PairingRequest], model: PairingInboxModel) -> some View {
        ForEach(requests) { request in
            PairingRequestRow(request: request, model: model) { self.approving = request }
        }
    }

    @ViewBuilder private func noRequests(_ model: PairingInboxModel) -> some View {
        Section {
            VStack(spacing: 6) {
                Image(systemName: "person.badge.key").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.channelFilterLabel.map { "No Requests for \($0)" } ?? "No Pending Requests").font(.headline)
                Text("When someone messages one of these accounts, their request shows up here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        Section {
            ForEach(model.visibleAccounts) { account in
                Label(account.summary, systemImage: "bubble.left.and.bubble.right")
            }
        } header: {
            Text("Accounts Using DM Pairing")
        } footer: {
            if let footer = Self.limitsText(model.limits) { Text(footer) }
        }
    }

    @ViewBuilder private func state(_ model: PairingInboxModel) -> some View {
        if model.requests.isEmpty, model.accounts.isEmpty {
            if !model.hasLoaded {
                ProgressView()
            } else if let error = model.loadState.error {
                ContentUnavailableView {
                    Label("Couldn't Load Pairing Requests", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            } else {
                ContentUnavailableView("No Channels Use DM Pairing", systemImage: "person.badge.key",
                                       description: Text("Set a channel's dmPolicy to \"pairing\" on the Gateway, and new senders will ask for access here."))
            }
        }
    }

    @ViewBuilder private func noticeView(_ model: PairingInboxModel) -> some View {
        if let notice = model.notice {
            Text(notice.text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule())
                .padding(.horizontal)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation { model.clearNotice() } }
                .task(id: notice.id) {
                    AccessibilityNotification.Announcement(notice.text).post()
                    try? await Task.sleep(for: .seconds(4))
                    if model.notice?.id == notice.id { withAnimation { model.clearNotice() } }
                }
        }
    }

    // MARK: Formatting

    private struct ChannelGroup: Hashable {
        let channel: String
        let label: String
        let requests: [PairingRequest]
    }

    /// One group per channel, in the order their newest request appears.
    private static func groups(_ requests: [PairingRequest]) -> [ChannelGroup] {
        var order: [String] = []
        var byChannel: [String: [PairingRequest]] = [:]
        for request in requests {
            if byChannel[request.channel] == nil { order.append(request.channel) }
            byChannel[request.channel, default: []].append(request)
        }
        return order.map { ChannelGroup(channel: $0, label: byChannel[$0]?.first?.channelLabel ?? $0, requests: byChannel[$0] ?? []) }
    }

    /// "Requests expire after 1 hour; up to 3 pending per account."
    static func limitsText(_ limits: PairingInboxModel.Limits?) -> String? {
        guard let limits else { return nil }
        var parts: [String] = []
        if let ttl = limits.ttl, ttl >= 60 { parts.append("Requests expire after \(PairingRequest.duration(ttl, style: .full))") }
        if let pending = limits.pendingPerAccount { parts.append("up to \(pending) pending per account") }
        guard let first = parts.first else { return nil }
        let sentence = ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: "; ")
        return sentence + "."
    }
}

// MARK: Row

private struct PairingRequestRow: View {
    let request: PairingRequest
    let model: PairingInboxModel
    let approve: () -> Void

    var body: some View {
        let operation = self.model.operation(for: self.request)
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let expired = self.request.isExpired(at: context.date)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.request.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    #if os(macOS)
                    self.buttons(busy: operation.isRunning, expired: expired)
                    #endif
                }
                Text(self.request.senderLine)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(self.request.accountLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(self.request.timing(at: context.date))
                    .font(.caption)
                    .foregroundStyle(expired ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .help(self.absoluteTimes)
                    .accessibilityValue(self.absoluteTimes)
                let details = self.request.details
                if !details.isEmpty {
                    DisclosureGroup("Details") {
                        ForEach(details, id: \.label) { detail in
                            LabeledContent(detail.label) { Text(detail.value).textSelection(.enabled) }
                                .font(.caption)
                        }
                    }
                    .font(.caption)
                }
                if let error = operation.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                #if os(iOS)
                HStack {
                    Spacer()
                    self.buttons(busy: operation.isRunning, expired: expired)
                }
                .padding(.top, 4)
                #endif
            }
            .padding(.vertical, 4)
        }
        .contextMenu {
            Button("Copy Sender ID", systemImage: "doc.on.doc") { Clipboard.copy(self.request.senderId) }
            Button("Copy Request ID", systemImage: "number") { Clipboard.copy(self.request.requestId) }
        }
    }

    @ViewBuilder private func buttons(busy: Bool, expired: Bool) -> some View {
        if busy { ProgressView().controlSize(.small) }
        Button("Dismiss") { Task { await self.model.dismiss(self.request) } }
            .buttonStyle(.bordered)
            .disabled(busy)
            .help("Removes this request. The sender isn't blocked and can ask again.")
            .accessibilityLabel("Dismiss \(self.request.title)")
        Button("Approve", action: self.approve)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Approve \(self.request.title)")
            .disabled(busy || expired)
            .help(expired ? "This request expired." : "Let this sender message your agents")
    }

    private var absoluteTimes: String {
        func line(_ label: String, _ date: Date?) -> String? {
            date.map { "\(label): \($0.formatted(date: .abbreviated, time: .shortened))" }
        }
        return [
            line("Requested", self.request.createdAt),
            self.request.showsLastSeen ? line("Last seen", self.request.lastSeenAt) : nil,
            line("Expires", self.request.expiresAt),
        ].compactMap(\.self).joined(separator: "\n")
    }
}

// MARK: Approve

/// Confirms who gets in: the channel's sender id (trustworthy) comes first; name and username
/// are what the sender set.
private struct ApprovePairingSheet: View {
    let request: PairingRequest
    let model: PairingInboxModel
    @State private var notify = true
    @State private var makeCommandOwner = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let canBootstrap = self.model.canBootstrapCommandOwner
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Let \(self.request.title) message your agents?")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent(self.request.senderLabel) {
                        Text(self.request.senderId).font(.body.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Channel", value: self.request.accountLine)
                } footer: {
                    Text("They'll be able to DM the agent on this account. To revoke access later, edit the channel's allowlist on the Gateway.")
                }
                if self.request.notifySupported || canBootstrap {
                    Section {
                        if self.request.notifySupported {
                            Toggle("Tell them they were approved", isOn: self.$notify)
                        }
                        if canBootstrap {
                            Toggle("Make them the command owner", isOn: self.$makeCommandOwner)
                        }
                    } footer: {
                        if canBootstrap {
                            Text("This Gateway has no command owner yet. The command owner can run owner-only commands from this channel.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let expired = self.request.isExpired(at: context.date)
                HStack {
                    if expired {
                        Text(PairingInboxModel.expiredMessage).font(.callout).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { self.dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Approve") {
                        let request = self.request
                        let notify = self.notify
                        let owner = canBootstrap && self.makeCommandOwner
                        let model = self.model
                        Task { await model.approve(request, notify: notify, makeCommandOwner: owner) }
                        self.dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(expired)
                }
                .padding()
            }
        }
        #if os(macOS)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
