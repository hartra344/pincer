import Charts
import PincerKit
import SwiftUI

// MARK: Categories

/// The four token types, in the same colors on every usage chart and grid.
enum UsageCategory: String, CaseIterable, Identifiable {
    case input
    case output
    case cacheRead
    case cacheWrite

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        case .cacheRead: "Cache read"
        case .cacheWrite: "Cache write"
        }
    }

    var color: Color {
        switch self {
        case .input: .blue
        case .output: .green
        case .cacheRead: .orange
        case .cacheWrite: .purple
        }
    }

    func tokens(_ totals: UsageTotals) -> Int {
        switch self {
        case .input: totals.input
        case .output: totals.output
        case .cacheRead: totals.cacheRead
        case .cacheWrite: totals.cacheWrite
        }
    }

    func cost(_ totals: UsageTotals) -> Double {
        switch self {
        case .input: totals.inputCost
        case .output: totals.outputCost
        case .cacheRead: totals.cacheReadCost
        case .cacheWrite: totals.cacheWriteCost
        }
    }

    static var scale: KeyValuePairs<String, Color> {
        [Self.input.label: Self.input.color, Self.output.label: Self.output.color,
         Self.cacheRead.label: Self.cacheRead.color, Self.cacheWrite.label: Self.cacheWrite.color]
    }
}

enum UsageMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens

    var id: String { self.rawValue }
    var label: String { self == .cost ? "Cost" : "Tokens" }

    /// Cost, unless nothing in `totals` was priced.
    static func preferred(_ totals: UsageTotals?) -> UsageMetric {
        guard let totals else { return .cost }
        if case .unknown = totals.costStatus { return .tokens }
        return .cost
    }
}

// MARK: Section states

/// What a section shows around its content: loading, unsupported, forbidden or failed.
@MainActor
struct UsageSectionStatus {
    var supported: Bool
    var hasValue: Bool
    var isFirstLoad: Bool
    var isRunning: Bool
    var error: String?
    var isForbidden: Bool
    var retry: @MainActor () async -> Void

    init<Value>(_ section: UsageSection<Value>, retry: @escaping @MainActor () async -> Void) {
        self.supported = section.supported
        self.hasValue = section.value != nil
        self.isFirstLoad = section.isFirstLoad
        self.isRunning = section.loadState.isRunning
        self.error = section.loadState.error
        self.isForbidden = section.isForbidden
        self.retry = retry
    }

    /// `primary` when it has something to show, else `fallback` (e.g. `usage.cost` totals when
    /// `sessions.usage` is missing).
    static func preferring(_ primary: Self, _ fallback: Self) -> Self {
        if primary.hasValue { return primary }
        if fallback.hasValue { return fallback }
        if !primary.supported { return fallback }
        if !fallback.supported { return primary }
        if primary.isFirstLoad { return primary }
        if fallback.isFirstLoad { return fallback }
        return primary
    }
}

/// A section's body: its content once loaded, else a placeholder the section's height, an
/// unsupported or forbidden note, or the error with Try Again.
struct UsageSectionBody<Content: View>: View {
    let status: UsageSectionStatus
    let unsupported: String
    var isEmpty = false
    var empty = "No usage in this range."
    var emptySymbol = "chart.bar"
    var height: CGFloat = 60
    @ViewBuilder let content: () -> Content
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let connected = self.gateway.state.isConnected
        if !self.status.supported {
            Text(self.unsupported)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if self.status.hasValue {
            if let error = self.status.error {
                UsageErrorLabel(message: error, forbidden: self.status.isForbidden, connected: connected, retry: self.status.retry)
            }
            if self.isEmpty {
                ContentUnavailableView(self.empty, systemImage: self.emptySymbol)
                    .frame(maxWidth: .infinity, minHeight: self.height)
            } else {
                self.content()
            }
        } else if self.status.isFirstLoad, connected || self.status.isRunning {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: self.height)
        } else if let error = self.status.error {
            UsageErrorLabel(message: error, forbidden: self.status.isForbidden, connected: connected, retry: self.status.retry)
        } else {
            Text("Not connected.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct UsageErrorLabel: View {
    let message: String
    var forbidden = false
    let connected: Bool
    let retry: @MainActor () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.forbidden {
                Label(self.message, systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else {
                Label(self.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Button("Try Again") { Task { await self.retry() } }
                .disabled(!self.connected)
        }
        .font(.callout)
    }
}

// MARK: Tiles

struct UsageTile: View {
    let title: String
    let value: String
    var detail: String?
    var help: String?
    var accessibilityValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(self.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.title)
        .accessibilityValue([self.accessibilityValue ?? self.value, self.detail].compactMap(\.self).joined(separator: ", "))
    }
}

/// Tiles in one row when they fit, else two by two, else stacked.
struct UsageTileGrid: View {
    let tiles: [UsageTile]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(self.tiles.indices, id: \.self) { self.tiles[$0].frame(minWidth: 130) }
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: self.tiles.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(start ..< min(start + 2, self.tiles.count), id: \.self) { self.tiles[$0].frame(minWidth: 120) }
                    }
                }
            }
            VStack(spacing: 10) {
                ForEach(self.tiles.indices, id: \.self) { self.tiles[$0] }
            }
        }
    }
}

extension UsageTile {
    static func cost(_ totals: UsageTotals, title: String = "Total cost") -> UsageTile {
        let cost = UsageFormat.cost(totals)
        let (detail, spoken): (String?, String) = switch cost.status {
        case .known: (nil, cost.text)
        case .partial: (cost.note, cost.amount ?? cost.text)
        case .unknown: ("Pricing unavailable", cost.accessibilityLabel)
        }
        return UsageTile(title: title, value: cost.text, detail: detail, help: cost.note, accessibilityValue: spoken)
    }

    static func tokens(_ totals: UsageTotals, title: String = "Total tokens") -> UsageTile {
        let detail = "In \(UsageFormat.tokens(totals.input)) · Out \(UsageFormat.tokens(totals.output)) · Cache \(UsageFormat.tokens(totals.cacheTokens))"
        return UsageTile(title: title, value: UsageFormat.tokens(totals.totalTokens), detail: detail,
                         accessibilityValue: UsageFormat.tokensSpoken(totals.totalTokens))
    }
}

// MARK: Costs

/// A cost with its unknown/partial marker and explanation.
struct UsageCostText: View {
    let totals: UsageTotals

    var body: some View {
        let cost = UsageFormat.cost(self.totals)
        Text(cost.text)
            .monospacedDigit()
            .foregroundStyle(cost.status == .known ? .primary : .secondary)
            .help(cost.note ?? "")
            .accessibilityLabel(cost.accessibilityLabel)
    }
}

// MARK: Names

@MainActor
enum UsageNames {
    /// The row's label, else its chat's title, else the key.
    static func session(key: String, label: String?, gateway: GatewayStore) -> String {
        if let label, !label.isEmpty { return label }
        if let title = gateway.sessions[key]?.title, !title.isEmpty { return title }
        return UsageFormat.middleTruncated(key)
    }

    static func agent(_ id: String?, gateway: GatewayStore) -> String {
        guard let id, !id.isEmpty else { return "Unknown" }
        return gateway.agent(id).name
    }

    static func model(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "Unknown" }
        return ModelRef.shortName(model)
    }

    static func provider(_ provider: String?) -> String {
        guard let provider, !provider.isEmpty else { return "Unknown" }
        return provider
    }

    /// "Claw · gpt-5.6-sol".
    static func subtitle(agentId: String?, model: String?, gateway: GatewayStore) -> String {
        var parts = [self.agent(agentId, gateway: gateway)]
        if let model, !model.isEmpty { parts.append(ModelRef.shortName(model)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Range picker

/// The range presets, custom dates and what the Gateway reported, pinned above a usage page.
struct UsageRangeBar: View {
    let selection: UsageRangeSelection
    let caption: String?
    var note: String?
    let enabled: Bool
    let apply: @MainActor (UsageRangeSelection) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Picker("Range", selection: Binding(
                get: { self.selection.preset },
                set: { preset in
                    var selection = self.selection
                    selection.preset = preset
                    self.apply(selection)
                }
            )) {
                ForEach(UsageRangePreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if self.selection.preset == .custom {
                self.customDates
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!self.enabled)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var customDates: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let range = self.selection.range()
        return HStack {
            DatePicker("From", selection: Binding(
                get: { range.start },
                set: { start in
                    var selection = self.selection
                    selection.customStart = min(start, today)
                    if selection.customEnd < selection.customStart { selection.customEnd = selection.customStart }
                    self.apply(selection)
                }
            ), in: ...today, displayedComponents: .date)
            DatePicker("To", selection: Binding(
                get: { range.end },
                set: { end in
                    var selection = self.selection
                    selection.customEnd = min(max(end, range.start), today)
                    self.apply(selection)
                }
            ), in: range.start ... max(range.start, today), displayedComponents: .date)
        }
        .fixedSize()
    }
}

extension UsageModel {
    /// "Sep 20 – Sep 26 · Updated 2 min. ago".
    var rangeCaption: String? {
        let range = self.displayedRange
        var parts = [UsageFormat.range(start: range.startKey, end: range.endKey)].compactMap(\.self)
        if let updatedAt { parts.append("Updated \(updatedAt.formatted(.relative(presentation: .named)))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var cacheNote: String? {
        self.cacheStatus == nil ? nil : "Some sessions are still being counted — totals may change."
    }
}
