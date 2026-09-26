import Charts
import PincerKit
import SwiftUI

/// One session's usage: totals for a range, the whole session's cumulative usage, and its
/// latest log entries (`sessions.usage` with `key`, `sessions.usage.timeseries`, `.logs`).
struct SessionUsagePage: View {
    let sessionKey: String
    let agentId: String?
    @Environment(GatewayStore.self) private var gateway
    @State private var loadedConnection = false

    private var model: UsageModel { self.gateway.usage }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        let detail = model.detail(self.sessionKey)
        let row = detail?.row
        let title = UsageNames.session(key: self.sessionKey, label: row?.label, gateway: self.gateway)
        let chat = self.gateway.sessions[self.sessionKey]
        let subtitle = UsageNames.subtitle(agentId: row?.agentId ?? self.agentId ?? SessionKey.agentId(from: self.sessionKey),
                                           model: row?.model ?? chat?.modelRef, gateway: self.gateway)
        let loading = detail.map { $0.totals.loadState.isRunning || $0.timeseries.loadState.isRunning || $0.logs.loadState.isRunning } ?? false
        Group {
            if !connected, detail?.totals.value == nil, detail?.timeseries.value == nil, detail?.logs.value == nil {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see this session's usage."))
            } else {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let detail {
                        SessionTotalsSection(model: model, detail: detail)
                        SessionTimeseriesSection(model: model, detail: detail)
                        SessionLogsSection(model: model, detail: detail)
                    }
                    if !connected {
                        Section { } footer: { Text("Not connected.") }
                    }
                }
                .formStyle(.grouped)
                #if os(macOS)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                #else
                .refreshable { if connected { await model.loadSession(self.sessionKey) } }
                #endif
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let detail {
                        let range = model.sessionRange(self.sessionKey)
                        UsageRangeBar(selection: detail.selection,
                                      caption: UsageFormat.range(start: range.startKey, end: range.endKey), enabled: connected) { selection in
                            Task { await model.setSessionSelection(self.sessionKey, selection) }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                if loading, detail?.totals.value != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.loadSession(self.sessionKey) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(!connected || loading)
                        .help("Refresh")
                }
            }
        }
        .task(id: connected) {
            // Cached data shows at once; it's refreshed each time the page is opened.
            model.prepareSession(self.sessionKey, agentId: self.agentId)
            guard connected else {
                self.loadedConnection = false
                return
            }
            guard !self.loadedConnection else { return }
            self.loadedConnection = true
            await model.loadSession(self.sessionKey)
        }
    }
}

// MARK: Totals

private struct SessionTotalsSection: View {
    let model: UsageModel
    let detail: SessionUsageDetail

    var body: some View {
        let key = self.detail.key
        let status = UsageSectionStatus(self.detail.totals) { [model] in await model.loadSessionTotals(key) }
        let usage = self.detail.row?.usage
        let totals = usage?.totals ?? .zero
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't report usage by session.", height: 120) {
                if totals.isEmpty {
                    Text("No usage in this range.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                UsageTileGrid(tiles: [.cost(totals, title: "Cost"), .tokens(totals, title: "Tokens")])
                SessionCategoryGrid(totals: totals)
                if let usage {
                    self.facts(usage)
                }
            }
        } header: {
            Text("Totals")
        }
        if let usage, usage.modelUsage.count > 1 {
            Section("Models") {
                ForEach(Array(usage.modelUsage.enumerated()), id: \.offset) { _, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(UsageNames.model(item.model))
                            Text(UsageNames.provider(item.provider)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            UsageCostText(totals: item.totals)
                            Text("\(UsageFormat.tokens(item.totals.totalTokens)) tokens")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private func facts(_ usage: SessionUsageSummary) -> some View {
        if let messages = usage.messageCounts {
            LabeledContent("Messages", value: "\(messages.user) user · \(messages.assistant) assistant")
            LabeledContent("Tool calls", value: (usage.toolCalls ?? messages.toolCalls).formatted())
            if messages.errors > 0 {
                LabeledContent("Errors", value: messages.errors.formatted())
            }
        }
        if let duration = usage.durationMs, duration > 0 {
            LabeledContent("Duration", value: UsageFormat.duration(ms: duration))
        }
        if let first = usage.firstActivity {
            LabeledContent("First activity", value: first.formatted(date: .abbreviated, time: .shortened))
        }
        if let last = usage.lastActivity {
            LabeledContent("Last activity", value: last.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

/// Input, output, cache read and cache write: tokens and, when priced by type, cost.
private struct SessionCategoryGrid: View {
    let totals: UsageTotals

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(UsageCategory.allCases) { category in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(category.color).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(category.label)
                    }
                    Text(UsageFormat.tokens(category.tokens(self.totals)))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(self.totals.hasCostBreakdown ? UsageFormat.currency(category.cost(self.totals)) : "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(category.label)
                .accessibilityValue(self.spoken(category))
            }
        }
    }

    private func spoken(_ category: UsageCategory) -> String {
        let tokens = UsageFormat.tokensSpoken(category.tokens(self.totals))
        return self.totals.hasCostBreakdown ? "\(tokens), \(UsageFormat.currency(category.cost(self.totals)))" : tokens
    }
}

// MARK: Timeseries

private struct SessionTimeseriesSection: View {
    let model: UsageModel
    let detail: SessionUsageDetail
    @State private var metric: UsageMetric?

    var body: some View {
        let key = self.detail.key
        let status = UsageSectionStatus(self.detail.timeseries) { [model] in await model.loadTimeseries(key) }
        let points = self.detail.timeseries.value?.points ?? []
        let unpriced = !points.isEmpty && points.allSatisfy { $0.cumulativeCost == 0 } && points.contains { $0.cumulativeTokens > 0 }
        let metric = self.metric ?? (unpriced ? .tokens : UsageMetric.preferred(self.detail.row?.usage?.totals))
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't report usage over time.",
                             isEmpty: points.isEmpty, empty: "No usage recorded for this session yet.", height: 180) {
                Picker("Metric", selection: Binding(get: { metric }, set: { self.metric = $0 })) {
                    ForEach(UsageMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SessionTimeseriesChart(points: points, metric: metric)
            }
        } header: {
            Text("Usage Over Time")
        } footer: {
            Text("Entire session, not limited to the range above.")
        }
    }
}

private struct SessionTimeseriesChart: View {
    let points: [UsagePoint]
    let metric: UsageMetric
    @State private var selected: Date?

    var body: some View {
        Chart {
            ForEach(self.points) { point in
                AreaMark(x: .value("Time", point.timestamp), y: .value(self.metric.label, self.value(point)))
                    .foregroundStyle(Color.accentColor.opacity(0.18).gradient)
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                LineMark(x: .value("Time", point.timestamp), y: .value(self.metric.label, self.value(point)))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(point.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .accessibilityValue(self.spoken(point))
            }
            if let point = self.selectedPoint {
                RuleMark(x: .value("Time", point.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption.weight(.semibold))
                            Text(UsageFormat.currency(point.cumulativeCost)).font(.caption.monospacedDigit())
                            Text("\(UsageFormat.tokens(point.cumulativeTokens)) tokens").font(.caption.monospacedDigit())
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartXSelection(value: self.$selected)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(self.metric == .cost ? UsageFormat.axisCurrency(amount) : UsageFormat.tokens(Int(amount)))
                    }
                }
            }
        }
        .frame(height: 180)
        .padding(.top, 20)
    }

    private func value(_ point: UsagePoint) -> Double {
        self.metric == .cost ? point.cumulativeCost : Double(point.cumulativeTokens)
    }

    private func spoken(_ point: UsagePoint) -> String {
        "\(UsageFormat.currency(point.cumulativeCost)), \(UsageFormat.tokens(point.cumulativeTokens)) tokens so far"
    }

    private var selectedPoint: UsagePoint? {
        guard let selected else { return nil }
        return self.points.min { abs($0.timestamp.timeIntervalSince(selected)) < abs($1.timestamp.timeIntervalSince(selected)) }
    }
}

// MARK: Logs

private struct SessionLogsSection: View {
    let model: UsageModel
    let detail: SessionUsageDetail

    var body: some View {
        let key = self.detail.key
        let status = UsageSectionStatus(self.detail.logs) { [model] in await model.loadLogs(key) }
        let logs = self.detail.logs.value ?? []
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't report session logs.",
                             isEmpty: logs.isEmpty, empty: "No log entries for this session yet.", emptySymbol: "text.alignleft",
                             height: 120) {
                ForEach(logs) { SessionLogRow(entry: $0) }
            }
        } header: {
            Text("Log")
        } footer: {
            if logs.count >= UsageRequests.logLimit {
                Text("Showing the latest \(logs.count) entries.")
            }
        }
    }
}

private struct SessionLogRow: View {
    let entry: UsageLogEntry
    @State private var expanded = false

    var body: some View {
        let entry = self.entry
        VStack(alignment: .leading, spacing: 4) {
            Button { self.expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(entry.role))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityLabel(entry.role.label)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.role.label).font(.caption.weight(.semibold))
                            if let timestamp = entry.timestamp {
                                Text(timestamp.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !self.expanded {
                            Text(entry.content.isEmpty ? "No content" : entry.content)
                                .font(.callout)
                                .foregroundStyle(entry.content.isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        if let tokens = entry.tokens {
                            Text("\(UsageFormat.tokens(tokens)) tokens").font(.caption.monospacedDigit())
                        }
                        if let cost = entry.cost {
                            Text(UsageFormat.currency(cost)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(self.expanded ? "Collapses the entry" : "Shows the full entry")
            if self.expanded {
                Text(entry.content)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
            }
        }
    }

    static func symbol(_ role: UsageLogEntry.Role) -> String {
        switch role {
        case .user: "person"
        case .assistant: "sparkles"
        case .tool: "wrench.and.screwdriver"
        case .toolResult: "arrow.turn.down.left"
        case .other: "questionmark.circle"
        }
    }
}
