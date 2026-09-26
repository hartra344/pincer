import Charts
import PincerKit
import SwiftUI

/// Gateway Settings → Usage: tokens and estimated spend for a range, by day, model, provider,
/// agent and session, plus provider quotas (`usage.cost`, `sessions.usage`, `usage.status`).
struct UsagePage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var loadedConnection = false

    private var model: UsageModel { self.gateway.usage }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Group {
            if model.isUnavailable {
                ContentUnavailableView {
                    Label("Usage Isn't Available", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("This gateway doesn't report usage or cost. Update OpenClaw to see tokens, spend and rate limits.")
                } actions: {
                    Button("Check Again") { Task { await model.refresh() } }
                        .disabled(!connected || model.isLoading)
                }
            } else if !connected, !model.hasData, !model.isLoading {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see its usage and cost."))
            } else {
                self.form(model, connected: connected)
            }
        }
        .navigationTitle("Usage")
        .toolbar {
            // Stays available when usage is unsupported, so an updated gateway can be picked up.
            ToolbarItem {
                if model.isLoading, model.hasData {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(!connected || model.isLoading)
                        .help("Refresh")
                }
            }
        }
        .task(id: connected) {
            // Coming back from a session keeps what's loaded; connecting (again) reloads
            // everything, rate limits included.
            guard connected else {
                self.loadedConnection = false
                return
            }
            guard !self.loadedConnection else { return }
            self.loadedConnection = true
            await model.load(includeStatus: true)
        }
    }

    private func form(_ model: UsageModel, connected: Bool) -> some View {
        Form {
            UsageSummarySection(model: model)
            UsageDailySection(model: model)
            UsageBreakdownSection(model: model)
            UsageSessionsSection(model: model)
            UsageRateLimitsSection(model: model)
            if !connected {
                Section { } footer: { Text("Not connected.") }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        #else
        .refreshable { if connected { await model.refresh() } }
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            UsageRangeBar(selection: model.selection, caption: model.rangeCaption, note: model.cacheNote,
                          enabled: connected) { selection in
                Task { await model.setSelection(selection) }
            }
        }
    }
}

// MARK: Summary

private struct UsageSummarySection: View {
    let model: UsageModel

    var body: some View {
        let model = self.model
        let status = UsageSectionStatus.preferring(
            UsageSectionStatus(model.sessions) { await model.loadSessions() },
            UsageSectionStatus(model.cost) { await model.loadCost() }
        )
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't report usage totals.", height: 70) {
                if let totals = model.totals {
                    UsageTileGrid(tiles: self.tiles(totals))
                }
            }
        }
    }

    private func tiles(_ totals: UsageTotals) -> [UsageTile] {
        let sessions = self.model.sessions.value
        return [
            .cost(totals),
            .tokens(totals),
            UsageTile(title: "Sessions", value: sessions.map { $0.sessionCount.formatted() } ?? "—"),
            UsageTile(title: "Messages", value: sessions.map { $0.aggregates.messages.total.formatted() } ?? "—"),
        ]
    }
}

// MARK: Daily

private struct UsageDailySection: View {
    let model: UsageModel
    @State private var metric: UsageMetric?
    @State private var selectedDay: Date?

    var body: some View {
        let model = self.model
        let status = UsageSectionStatus.preferring(
            UsageSectionStatus(model.cost) { await model.loadCost() },
            UsageSectionStatus(model.sessions) { await model.loadSessions() }
        )
        let days = model.daily ?? []
        let metric = self.metric ?? UsageMetric.preferred(model.totals)
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't report daily usage.",
                             isEmpty: days.allSatisfy(\.totals.isEmpty), height: 200) {
                Picker("Metric", selection: Binding(get: { metric }, set: { self.metric = $0 })) {
                    ForEach(UsageMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                UsageDailyChart(days: days, metric: metric, selectedDay: self.$selectedDay)
            }
        } header: {
            Text("Daily")
        } footer: {
            if model.cost.isForbidden, model.cost.value == nil, let error = model.cost.loadState.error, status.hasValue {
                Label(error, systemImage: "lock")
            }
        }
    }
}

struct UsageDailyChart: View {
    let days: [UsageDay]
    let metric: UsageMetric
    @Binding var selectedDay: Date?

    private struct Bar: Identifiable {
        let id: String
        let date: Date
        let day: UsageDay
        let series: String?
        let value: Double
    }

    var body: some View {
        let stacked = self.metric == .tokens && self.days.contains(where: \.hasCategories)
        let bars = self.bars(stacked: stacked)
        Chart {
            ForEach(bars) { bar in
                if let series = bar.series {
                    BarMark(x: .value("Day", bar.date, unit: .day), y: .value(self.metric.label, bar.value))
                        .foregroundStyle(by: .value("Type", series))
                        .accessibilityLabel(UsageFormat.day(bar.day.date))
                        .accessibilityValue("\(series) \(UsageFormat.tokensSpoken(Int(bar.value)))")
                } else {
                    BarMark(x: .value("Day", bar.date, unit: .day), y: .value(self.metric.label, bar.value))
                        .foregroundStyle(Color.accentColor.gradient)
                        .accessibilityLabel(UsageFormat.day(bar.day.date))
                        .accessibilityValue(Self.spoken(bar.day))
                }
            }
            if let selected = self.selected {
                RuleMark(x: .value("Day", selected.date, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .zIndex(-1)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        self.annotation(selected.day)
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(UsageCategory.scale)
        .chartLegend(stacked ? .visible : .hidden)
        .usageChartSelection(self.$selectedDay)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
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
        .frame(height: 200)
        .padding(.top, 20)
    }

    private var selected: (date: Date, day: UsageDay)? {
        guard let selectedDay else { return nil }
        let calendar = UsageDates.calendar()
        let key = UsageDates.key(selectedDay, calendar: calendar)
        guard let day = self.days.first(where: { $0.date == key }),
              let date = UsageDates.date(fromKey: key, calendar: calendar) else { return nil }
        return (date, day)
    }

    private func bars(stacked: Bool) -> [Bar] {
        self.days.flatMap { day -> [Bar] in
            guard let date = UsageDates.date(fromKey: day.date) else { return [] }
            if stacked {
                return UsageCategory.allCases.map { category in
                    Bar(id: "\(day.date)-\(category.rawValue)", date: date, day: day, series: category.label,
                        value: Double(category.tokens(day.totals)))
                }
            }
            let value = self.metric == .cost ? day.totals.totalCost : Double(day.totals.totalTokens)
            return [Bar(id: day.date, date: date, day: day, series: nil, value: value)]
        }
    }

    /// "$1.20, 340k tokens".
    static func spoken(_ day: UsageDay) -> String {
        "\(UsageFormat.cost(day.totals).accessibilityLabel), \(UsageFormat.tokens(day.totals.totalTokens)) tokens"
    }

    private func annotation(_ day: UsageDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(UsageFormat.day(day.date)).font(.caption.weight(.semibold))
            Text(UsageFormat.cost(day.totals).text).font(.caption.monospacedDigit())
            Text("\(UsageFormat.tokens(day.totals.totalTokens)) tokens").font(.caption.monospacedDigit())
            if day.hasCategories, self.metric == .tokens {
                ForEach(UsageCategory.allCases) { category in
                    Text("\(category.label) \(UsageFormat.tokens(category.tokens(day.totals)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: Breakdown

private enum UsageBreakdownKind: String, CaseIterable, Identifiable {
    case model
    case provider
    case agent

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .model: "Model"
        case .provider: "Provider"
        case .agent: "Agent"
        }
    }
}

private struct UsageBreakdownSection: View {
    let model: UsageModel
    @State private var kind = UsageBreakdownKind.model
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let model = self.model
        let status = UsageSectionStatus(model.sessions) { await model.loadSessions() }
        let items = self.items(model.sessions.value?.aggregates)
        let byCost = UsageMetric.preferred(model.totals) == .cost
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't break usage down by model or agent.",
                             isEmpty: items.allSatisfy(\.totals.isEmpty), height: 160) {
                Picker("Group By", selection: self.$kind) {
                    ForEach(UsageBreakdownKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                let top = UsageBreakdownItem.top(items, byCost: byCost)
                UsageBreakdownChart(items: top, byCost: byCost)
                let total = items.reduce(0.0) { $0 + Self.value($1.totals, byCost: byCost) }
                ForEach(UsageBreakdownItem.top(items, byCost: byCost, limit: .max)) { item in
                    UsageBreakdownRow(item: item, share: total > 0 ? Self.value(item.totals, byCost: byCost) / total : 0)
                }
            }
        } header: {
            Text("Breakdown")
        }
    }

    static func value(_ totals: UsageTotals, byCost: Bool) -> Double {
        byCost ? totals.totalCost : Double(totals.totalTokens)
    }

    private func items(_ aggregates: SessionsUsageAggregates?) -> [UsageBreakdownItem] {
        guard let aggregates else { return [] }
        switch self.kind {
        case .model:
            return aggregates.byModel.map { usage in
                UsageBreakdownItem(id: "\(usage.provider ?? "")/\(usage.model ?? "")", title: UsageNames.model(usage.model),
                                   subtitle: UsageNames.provider(usage.provider), totals: usage.totals)
            }
        case .provider:
            return aggregates.byProvider.map { usage in
                UsageBreakdownItem(id: usage.provider ?? "", title: UsageNames.provider(usage.provider), totals: usage.totals)
            }
        case .agent:
            return aggregates.byAgent.map { usage in
                let name = UsageNames.agent(usage.key, gateway: self.gateway)
                return UsageBreakdownItem(id: usage.key, title: name, subtitle: name == usage.key || usage.key.isEmpty ? nil : usage.key,
                                          totals: usage.totals)
            }
        }
    }
}

private struct UsageBreakdownChart: View {
    let items: [UsageBreakdownItem]
    let byCost: Bool

    var body: some View {
        Chart(self.items) { item in
            BarMark(x: .value(self.byCost ? "Cost" : "Tokens", UsageBreakdownSection.value(item.totals, byCost: self.byCost)),
                    y: .value("Name", item.id))
                .foregroundStyle(item.isOther ? Color.secondary.gradient : Color.accentColor.gradient)
                .accessibilityLabel(item.title)
                .accessibilityValue("\(UsageFormat.cost(item.totals).accessibilityLabel), \(UsageFormat.tokensSpoken(item.totals.totalTokens))")
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let id = value.as(String.self) {
                        Text(self.items.first { $0.id == id }?.title ?? id).lineLimit(1)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(self.byCost ? UsageFormat.axisCurrency(amount) : UsageFormat.tokens(Int(amount)))
                    }
                }
            }
        }
        .frame(height: CGFloat(max(1, self.items.count)) * 26 + 24)
    }
}

private struct UsageBreakdownRow: View {
    let item: UsageBreakdownItem
    let share: Double

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.item.title).lineLimit(1).truncationMode(.middle)
                if let subtitle = self.item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if self.item.totals.missingCostEntries > 0 {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help(UsageFormat.cost(self.item.totals).note ?? "")
                            .accessibilityHidden(true)
                    }
                    UsageCostText(totals: self.item.totals)
                }
                Text("\(UsageFormat.tokens(self.item.totals.totalTokens)) tokens · \(self.share.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Sessions

struct SessionUsageItem: Identifiable {
    let row: SessionUsageRow
    let title: String
    let agent: String
    let model: String
    let tokens: Int
    let cost: Double
    let lastActive: Date

    var id: String { self.row.key }
}

private struct UsageSessionsSection: View {
    let model: UsageModel
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    #if os(macOS)
    @State private var sortOrder = [KeyPathComparator(\SessionUsageItem.cost, order: .reverse)]
    @State private var selection: String?
    #else
    @State private var sort = UsageSessionSort.cost
    #endif

    var body: some View {
        let model = self.model
        let status = UsageSectionStatus(model.sessions) { await model.loadSessions() }
        let result = model.sessions.value
        let rows = result?.sessions ?? []
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't report usage by session.",
                             isEmpty: rows.isEmpty, empty: "No sessions in this range.", emptySymbol: "bubble.left.and.bubble.right",
                             height: 120) {
                self.list(rows)
            }
        } header: {
            HStack {
                Text("Sessions")
                #if os(iOS)
                Spacer()
                Picker("Sort By", selection: self.$sort) {
                    ForEach(UsageSessionSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .font(.caption)
                #endif
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let result, result.sessionCount > result.sessions.count {
                    Text("Showing top \(result.sessions.count) of \(result.sessionCount) sessions.")
                }
                #if os(macOS)
                if !rows.isEmpty {
                    Text("Double-click a session for details.")
                }
                #endif
            }
        }
    }

    private func item(_ row: SessionUsageRow) -> SessionUsageItem {
        SessionUsageItem(row: row, title: UsageNames.session(key: row.key, label: row.label, gateway: self.gateway),
                         agent: UsageNames.agent(row.agentId, gateway: self.gateway), model: row.model.map(ModelRef.shortName) ?? "—",
                         tokens: row.usage?.totals.totalTokens ?? -1, cost: row.usage?.totals.totalCost ?? -1,
                         lastActive: row.lastActive ?? .distantPast)
    }

    private func open(_ row: SessionUsageRow) {
        self.model.prepareSession(row.key, agentId: row.agentId, selection: self.model.selection)
        self.navigator.path.append(.sessionUsage(key: row.key, agentId: row.agentId))
    }

    #if os(macOS)
    private var sort: (UsageSessionSort, Bool) {
        guard let first = self.sortOrder.first else { return (.cost, false) }
        let ascending = first.order == .forward
        if first.keyPath == \SessionUsageItem.tokens { return (.tokens, ascending) }
        if first.keyPath == \SessionUsageItem.lastActive { return (.recent, ascending) }
        return (.cost, ascending)
    }

    private func list(_ rows: [SessionUsageRow]) -> some View {
        let (sort, ascending) = self.sort
        let items = sort.sorted(rows, ascending: ascending).map(self.item)
        return Table(items, selection: self.$selection, sortOrder: self.$sortOrder) {
            TableColumn("Session") { item in
                Text(item.title).lineLimit(1).truncationMode(.middle).help(item.row.key)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Agent") { item in Text(item.agent).lineLimit(1) }
                .width(min: 60, ideal: 90)
            TableColumn("Model") { item in Text(item.model).lineLimit(1).truncationMode(.middle) }
                .width(min: 70, ideal: 120)
            TableColumn("Tokens", value: \.tokens) { item in
                self.numeric(item) { Text(UsageFormat.tokens($0.totalTokens)).monospacedDigit() }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Cost", value: \.cost) { item in
                self.numeric(item) { UsageCostText(totals: $0) }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Last Active", value: \.lastActive) { item in
                Text(item.row.lastActive?.formatted(.relative(presentation: .named)) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, let row = rows.first(where: { $0.key == key }) {
                Button("Show Usage") { self.open(row) }
                Button("Copy Session Key") { Clipboard.copy(key) }
            }
        } primaryAction: { keys in
            if let key = keys.first, let row = rows.first(where: { $0.key == key }) { self.open(row) }
        }
        .frame(height: min(CGFloat(items.count) * 24 + 32, 360))
    }

    @ViewBuilder private func numeric(_ item: SessionUsageItem, @ViewBuilder _ content: (UsageTotals) -> some View) -> some View {
        if let totals = item.row.usage?.totals {
            content(totals)
        } else {
            Text("Calculating…").foregroundStyle(.secondary)
        }
    }
    #else
    private func list(_ rows: [SessionUsageRow]) -> some View {
        ForEach(self.sort.sorted(rows).map(self.item)) { item in
            Button { self.open(item.row) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Text(UsageNames.subtitle(agentId: item.row.agentId, model: item.row.model, gateway: self.gateway))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        if let totals = item.row.usage?.totals {
                            UsageCostText(totals: totals)
                            Text("\(UsageFormat.tokens(totals.totalTokens)) tokens")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Calculating…").foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }
    #endif
}

// MARK: Rate limits

private struct UsageRateLimitsSection: View {
    let model: UsageModel

    var body: some View {
        let model = self.model
        let status = UsageSectionStatus(model.status) { await model.loadStatus() }
        let summary = model.status.value
        let providers = summary?.providers ?? []
        Section {
            UsageSectionBody(status: status, unsupported: "This gateway doesn't report rate limits. Update OpenClaw to see them.",
                             isEmpty: providers.isEmpty && summary?.refreshing != true,
                             empty: "No providers report quota information.", emptySymbol: "gauge.with.dots.needle.33percent") {
                if providers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing…").foregroundStyle(.secondary)
                    }
                }
                ForEach(providers) { UsageProviderView(provider: $0) }
            }
        } header: {
            Text("Rate Limits")
        }
    }
}

private struct UsageProviderView: View {
    let provider: ProviderUsage

    var body: some View {
        let provider = self.provider
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName).font(.headline)
                let secondary = [provider.plan, provider.accountEmail].compactMap(\.self)
                if !secondary.isEmpty {
                    Text(secondary.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = provider.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                    UsageWindowView(provider: provider.displayName, window: window)
                }
                if provider.windows.isEmpty, provider.billing.isEmpty {
                    Text(provider.summary ?? "No quota information.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(provider.billing.enumerated()), id: \.offset) { _, billing in
                UsageBillingView(billing: billing)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct UsageWindowView: View {
    let provider: String
    let window: UsageWindow

    var body: some View {
        let level = UsageLevel(usedPercent: self.window.usedPercent)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(self.window.title)
                Spacer()
                Text(UsageFormat.percent(self.window.usedPercent))
                    .monospacedDigit()
                    .foregroundStyle(level == .normal ? Color.secondary : Self.color(level))
            }
            .font(.callout)
            ProgressView(value: UsageFormat.fraction(self.window.usedPercent))
                .tint(Self.color(level))
            if let reset = self.window.resetAt {
                Text(UsageFormat.reset(reset)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.provider) \(self.window.title) window")
        .accessibilityValue(self.spokenValue)
    }

    private var spokenValue: String {
        var value = "\(UsageFormat.percent(self.window.usedPercent).replacingOccurrences(of: "%", with: " percent")) used"
        if let reset = self.window.resetAt { value += ", \(UsageFormat.resetSpoken(reset))" }
        return value
    }

    static func color(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct UsageBillingView: View {
    let billing: UsageBilling

    var body: some View {
        let billing = self.billing
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(billing.title) {
                Text(self.value).monospacedDigit()
            }
            .font(.callout)
            if billing.kind == .budget, let used = billing.used, let limit = billing.limit, limit > 0 {
                let percent = used / limit * 100
                ProgressView(value: UsageFormat.fraction(percent))
                    .tint(UsageWindowView.color(UsageLevel(usedPercent: percent)))
                    .accessibilityLabel("\(billing.title) used")
                    .accessibilityValue(UsageFormat.percent(percent).replacingOccurrences(of: "%", with: " percent"))
            }
            if let reset = billing.resetAt {
                Text(UsageFormat.reset(reset)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var value: String {
        let billing = self.billing
        let format = { (value: Double) in UsageFormat.amount(value, unit: billing.unit) }
        var text: String
        if let used = billing.used, let limit = billing.limit {
            text = "\(format(used)) / \(format(limit))"
        } else if let amount = billing.amount ?? billing.used {
            text = format(amount)
        } else {
            text = "—"
        }
        if let period = billing.period { text += " · \(period)" }
        return text
    }
}
