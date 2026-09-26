import PincerKit
import SwiftUI

/// Gateway Settings → Health: how the Gateway is doing, its channels and connected clients, and a
/// safe restart (`health`, `last-heartbeat`, `system-presence`, `gateway.restart.request`).
struct GatewayHealthPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirmRestart = false
    @State private var confirmForce = false

    private var model: GatewayHealthModel { self.gateway.health }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Form {
            if Self.showsRestartBanner(model) {
                self.restartBanner(model)
            }
            self.summary(model, connected: connected)
            let issues = model.issues
            if !issues.isEmpty {
                Section("Issues") {
                    ForEach(issues) { issue in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.title)
                                if let detail = issue.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        } icon: {
                            Image(systemName: issue.symbol).foregroundStyle(.orange)
                        }
                    }
                }
            }
            self.channels(model)
            self.clients(model)
            self.restartSection(model)
        }
        .formStyle(.grouped)
        .navigationTitle("Health")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!connected || model.loadState.isRunning)
                    .help("Refresh")
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
                await model.refresh()
            }
        }
        .confirmationDialog("Restart Gateway?", isPresented: self.$confirmRestart, titleVisibility: .visible) {
            Button("Restart Gateway", role: .destructive) { Task { await model.restart() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running replies and tasks finish first. Connected clients disconnect briefly.")
        }
        .confirmationDialog("Restart now anyway?", isPresented: self.$confirmForce, titleVisibility: .visible) {
            Button("Restart Now", role: .destructive) { Task { await model.restart(skipDeferral: true) } }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text("Replies and tasks that are still running are interrupted. Connected clients disconnect briefly.")
        }
    }

    // MARK: Sections

    static func showsRestartBanner(_ model: GatewayHealthModel) -> Bool {
        model.needsRestart && !model.restartState.isInProgress
    }

    private func restartBanner(_ model: GatewayHealthModel) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart needed to apply changes")
                    if let reason = model.restartRequiredReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("A channel is waiting for a Gateway restart.").font(.caption).foregroundStyle(.secondary)
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
            LabeledContent("Status") {
                Label(level.label, systemImage: level.symbol).foregroundStyle(Self.color(level))
            }
            if let failure = model.healthFailure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
            if let version = model.serverVersion ?? self.gateway.hello?.serverVersion {
                LabeledContent("Version", value: version)
            }
            LabeledContent("Uptime") {
                if connected, let started = model.startedAt {
                    Text(started, style: .relative)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Last heartbeat") { self.heartbeat(model) }
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
            Text("Unavailable on this Gateway").foregroundStyle(.secondary)
        } else if model.heartbeatLoaded {
            Text("No heartbeat yet").foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func channels(_ model: GatewayHealthModel) -> some View {
        Section("Channels") {
            if let health = model.health {
                if health.channels.isEmpty {
                    Text("No channels are set up.").foregroundStyle(.secondary)
                }
                ForEach(health.channels) { channel in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.label)
                            if let error = channel.lastError {
                                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Text(channel.status.label).foregroundStyle(Self.color(channel.status))
                    }
                }
            } else if !model.isAvailable(.health) {
                Text("Unavailable on this Gateway").foregroundStyle(.secondary)
            } else {
                Text(model.hasLoaded ? "No channel details yet." : "Loading…").foregroundStyle(.secondary)
            }
        }
    }

    private func clients(_ model: GatewayHealthModel) -> some View {
        Section("Connected Clients") {
            let entries = model.sortedPresence
            if entries.isEmpty {
                Text(model.isAvailable(.presence) ? "No clients reported." : "Unavailable on this Gateway")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                        if model.isThisDevice(entry) {
                            Text("This device")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    let details = [entry.deviceSummary, entry.roleSummary].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let activity = entry.lastActivityAt {
                        Text("Active \(Text(activity, style: .relative)) ago").font(.caption).foregroundStyle(.secondary)
                    } else if let since = entry.onlineSince {
                        Text("Online for \(Text(since, style: .relative))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func restartSection(_ model: GatewayHealthModel) -> some View {
        Section {
            if let message = model.restartState.message {
                HStack(spacing: 8) {
                    if model.restartState.isInProgress {
                        ProgressView().controlSize(.small)
                    }
                    self.restartStatus(model, message: message)
                    Spacer()
                    switch model.restartState {
                    case .restarted, .failed:
                        Button("Dismiss") { model.dismissRestartStatus() }.buttonStyle(.borderless)
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
                Button("Restart Now Anyway…", role: .destructive) { self.confirmForce = true }
            }
        } header: {
            Text("Restart")
        } footer: {
            Text("The Gateway waits for running replies and tasks to finish, then restarts. Pincer reconnects on its own.")
        }
    }

    @ViewBuilder private func restartStatus(_ model: GatewayHealthModel, message: String) -> some View {
        switch model.restartState {
        case .restarted:
            VStack(alignment: .leading, spacing: 2) {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let started = model.startedAt {
                    Text("Up for \(Text(started, style: .relative))").font(.caption).foregroundStyle(.secondary)
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
            Text("Restarting is unavailable on this Gateway.").foregroundStyle(.secondary)
        } else if !model.hasAdmin {
            Button {
                self.navigator.destination = .connection
            } label: {
                Label("Restarting needs Full Management access", systemImage: "lock")
            }
            .help("Open Connection to turn on Full Management.")
        } else {
            Button("Restart Gateway…", systemImage: "arrow.clockwise") { self.confirmRestart = true }
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

    static func color(_ status: GatewayChannelHealth.Status) -> Color {
        switch status {
        case .connected, .running: .green
        case .stopped: .orange
        case .error: .red
        case .disabled, .notConfigured, .unknown: .secondary
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
        .help("Open Gateway Health")
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
