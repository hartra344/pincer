import Foundation

// MARK: Model

/// One usage method's state: whether the Gateway has it, the last value and how its load went.
public struct UsageSection<Value: Sendable>: Sendable {
    public internal(set) var value: Value?
    /// False when the Gateway doesn't have the method.
    public internal(set) var supported = true
    public internal(set) var hasLoaded = false
    public internal(set) var loadState = OperationState.idle
    /// The Gateway refused (`FORBIDDEN`), e.g. aggregate cost for a restricted operator.
    public internal(set) var isForbidden = false

    public init() {}

    /// Nothing to show yet and a load is due or running.
    public var isFirstLoad: Bool { self.supported && self.value == nil && (!self.hasLoaded || self.loadState.isRunning) }

    mutating func markUnsupported() {
        self.supported = false
        self.value = nil
        self.loadState = .idle
        self.isForbidden = false
        self.hasLoaded = true
    }
}

/// A session's drill-down: range-bound totals, whole-session timeseries and logs.
public struct SessionUsageDetail: Sendable {
    public let key: String
    public internal(set) var agentId: String?
    public internal(set) var selection: UsageRangeSelection
    public internal(set) var totals = UsageSection<SessionsUsageResult>()
    public internal(set) var timeseries = UsageSection<UsageTimeSeries>()
    public internal(set) var logs = UsageSection<[UsageLogEntry]>()

    init(key: String, agentId: String?, selection: UsageRangeSelection) {
        self.key = key
        self.agentId = agentId
        self.selection = selection
    }

    /// This session's row in the range, if it had usage.
    public var row: SessionUsageRow? {
        self.totals.value.flatMap { result in result.sessions.first { $0.key == self.key } ?? result.sessions.first }
    }
}

/// Usage & cost for one Gateway: `usage.status`, `usage.cost` and `sessions.usage` for the
/// dashboard, and per-session drill-downs. Each method loads, fails and degrades on its own.
@MainActor
@Observable
public final class UsageModel {
    public private(set) var status = UsageSection<UsageStatusSummary>()
    public private(set) var cost = UsageSection<CostUsageSummary>()
    public private(set) var sessions = UsageSection<SessionsUsageResult>()
    public private(set) var selection = UsageRangeSelection()
    /// Drill-downs by session key, kept for the model's lifetime.
    public private(set) var details: [String: SessionUsageDetail] = [:]

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public nonisolated static let methods = ["usage.status", "usage.cost", "sessions.usage", "sessions.usage.timeseries",
                                             "sessions.usage.logs"]
    public nonisolated static var decodeFailure: String { L("The Gateway sent usage data Pincer couldn't read.") }

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var generations: [String: Int] = [:]

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?) {
        self.request = { method, params in try await connection.request(method, params, timeout: 60) }
        self.methods = { hello()?.methods }
        self.now = { Date() }
    }

    /// For checks and previews: `methods` is the Gateway's advertised method list (nil or empty
    /// when unknown), `request` answers RPCs.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil }, now: @escaping @MainActor () -> Date = { Date() },
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.now = now
    }

    public var range: UsageDateRange { self.selection.range(now: self.now()) }

    /// All three dashboard methods are missing.
    public var isUnavailable: Bool { !self.status.supported && !self.cost.supported && !self.sessions.supported }
    public var isLoading: Bool { self.status.loadState.isRunning || self.cost.loadState.isRunning || self.sessions.loadState.isRunning }
    public var hasLoaded: Bool { self.status.hasLoaded && self.cost.hasLoaded && self.sessions.hasLoaded }
    public var hasData: Bool { self.status.value != nil || self.cost.value != nil || self.sessions.value != nil }

    /// Totals for the tiles: `sessions.usage`, else `usage.cost`.
    public var totals: UsageTotals? { self.sessions.value?.totals ?? self.cost.value?.totals }

    /// The chart's days across the whole range: `usage.cost`, else `costDaily`, else `aggregates.daily`.
    public var daily: [UsageDay]? {
        let range = self.displayedRange
        if let days = self.cost.value?.daily { return UsageDay.filled(days, range: range) }
        guard let aggregates = self.sessions.value?.aggregates else { return nil }
        return UsageDay.filled(aggregates.costDaily ?? aggregates.daily, range: range)
    }

    /// The range the Gateway reported, else the one asked for.
    public var displayedRange: UsageDateRange {
        let calendar = self.range.calendar
        let start = self.sessions.value?.startDate ?? self.cost.value?.daily.first?.date
        let end = self.sessions.value?.endDate
        if let start, let end, let from = UsageDates.date(fromKey: start, calendar: calendar),
           let to = UsageDates.date(fromKey: end, calendar: calendar)
        {
            return UsageDateRange(start: from, end: to, calendar: calendar)
        }
        return self.range
    }

    public var cacheStatus: UsageCacheStatus? {
        [self.sessions.value?.cacheStatus, self.cost.value?.cacheStatus].compactMap(\.self).first { $0.isIncomplete }
    }

    public var updatedAt: Date? { self.sessions.value?.updatedAt ?? self.cost.value?.updatedAt }

    // MARK: Dashboard

    /// Loads every dashboard method. `usage.status` isn't range-bound, so it's only fetched
    /// the first time, when it was unsupported (the Gateway may have been updated) or when
    /// `includeStatus` asks (Refresh, reconnect). A forbidden `usage.cost` waits for an
    /// explicit refresh.
    public func load(includeStatus: Bool = false, force: Bool = false) async {
        let reloadStatus = includeStatus || !self.status.hasLoaded || !self.status.supported
        let reloadCost = force || !self.cost.isForbidden
        async let status: Void = self.loadStatus(if: reloadStatus)
        async let cost: Void = self.loadCost(if: reloadCost)
        async let sessions: Void = self.loadSessions()
        _ = await (status, cost, sessions)
    }

    /// Refresh: all three methods, forbidden ones included.
    public func refresh() async { await self.load(includeStatus: true, force: true) }

    public func loadStatus() async {
        await self.perform("usage.status", [:], into: \.status, decode: UsageStatusSummary.init)
    }

    private func loadStatus(if needed: Bool) async { if needed { await self.loadStatus() } }
    private func loadCost(if needed: Bool) async { if needed { await self.loadCost() } }

    public func loadCost() async {
        await self.perform("usage.cost", UsageRequests.cost(self.range, at: self.now()), into: \.cost,
                           decode: CostUsageSummary.init)
    }

    public func loadSessions() async {
        await self.perform("sessions.usage", UsageRequests.sessions(self.range, at: self.now()), into: \.sessions,
                           decode: SessionsUsageResult.init)
    }

    /// Changes the range and reloads what depends on it.
    public func setSelection(_ selection: UsageRangeSelection) async {
        guard selection != self.selection else { return }
        self.selection = selection
        await self.load()
    }

    public func setPreset(_ preset: UsageRangePreset) async {
        var selection = self.selection
        selection.preset = preset
        await self.setSelection(selection)
    }

    // MARK: Sessions

    /// Readies a drill-down, keeping what's cached. `selection` (e.g. the dashboard's range)
    /// replaces the session's own range when given; new drill-downs default to 30 days.
    public func prepareSession(_ key: String, agentId: String? = nil, selection: UsageRangeSelection? = nil) {
        if var detail = self.details[key] {
            if let agentId { detail.agentId = agentId }
            if let selection, selection != detail.selection {
                detail.selection = selection
                detail.totals.value = nil
            }
            self.details[key] = detail
        } else {
            self.details[key] = SessionUsageDetail(key: key, agentId: agentId ?? SessionKey.agentId(from: key),
                                                   selection: selection ?? UsageRangeSelection(preset: .month, now: self.now()))
        }
    }

    public func detail(_ key: String) -> SessionUsageDetail? { self.details[key] }

    /// Loads the drill-down's totals, timeseries and logs, each on its own.
    public func loadSession(_ key: String) async {
        self.prepareSession(key)
        async let totals: Void = self.loadSessionTotals(key)
        async let series: Void = self.loadTimeseries(key)
        async let logs: Void = self.loadLogs(key)
        _ = await (totals, series, logs)
    }

    public func setSessionSelection(_ key: String, _ selection: UsageRangeSelection) async {
        self.prepareSession(key, selection: selection)
        await self.loadSessionTotals(key)
    }

    public func sessionRange(_ key: String) -> UsageDateRange {
        (self.details[key]?.selection ?? UsageRangeSelection(preset: .month, now: self.now())).range(now: self.now())
    }

    public func loadSessionTotals(_ key: String) async {
        self.prepareSession(key)
        let agentId = self.details[key]?.agentId
        let params = UsageRequests.session(key: key, agentId: agentId, range: self.sessionRange(key), at: self.now())
        await self.perform("sessions.usage", params, session: key, \.totals, decode: SessionsUsageResult.init)
    }

    public func loadTimeseries(_ key: String) async {
        self.prepareSession(key)
        let params = UsageRequests.timeseries(key: key, agentId: self.details[key]?.agentId)
        await self.perform("sessions.usage.timeseries", params, session: key, \.timeseries,
                           decode: UsageTimeSeries.init) { error in
            // No transcript yet is an empty session, not a failure.
            guard case let GatewayError.rpc(code, message, _) = error, code == "INVALID_REQUEST",
                  message.lowercased().contains("no transcript") else { return nil }
            return .empty
        }
    }

    public func loadLogs(_ key: String) async {
        self.prepareSession(key)
        let params = UsageRequests.logs(key: key, agentId: self.details[key]?.agentId)
        await self.perform("sessions.usage.logs", params, session: key, \.logs, decode: UsageLogEntry.decode)
    }

    private func placeholder(_ key: String) -> SessionUsageDetail {
        SessionUsageDetail(key: key, agentId: SessionKey.agentId(from: key), selection: UsageRangeSelection(preset: .month, now: self.now()))
    }

    // MARK: Requests

    private typealias Edit<Value: Sendable> = (_ change: (inout UsageSection<Value>) -> Void) -> Void

    private func perform<Value: Sendable>(
        _ method: String, _ params: JSONValue, into path: ReferenceWritableKeyPath<UsageModel, UsageSection<Value>>,
        decode: (JSONValue) -> Value?
    ) async {
        await self.perform(method, params, token: method, edit: { change in change(&self[keyPath: path]) }, decode: decode)
    }

    private func perform<Value: Sendable>(
        _ method: String, _ params: JSONValue, session key: String,
        _ path: WritableKeyPath<SessionUsageDetail, UsageSection<Value>>, decode: (JSONValue) -> Value?,
        recover: ((Error) -> Value?)? = nil
    ) async {
        let placeholder = self.placeholder(key)
        await self.perform(method, params, token: "\(method):\(key)",
                           edit: { change in change(&self.details[key, default: placeholder][keyPath: path]) },
                           decode: decode, recover: recover)
    }

    private func perform<Value: Sendable>(
        _ method: String, _ params: JSONValue, token: String, edit: Edit<Value>,
        decode: (JSONValue) -> Value?, recover: ((Error) -> Value?)? = nil
    ) async {
        if let methods = self.methods(), !methods.isEmpty, !methods.contains(method) {
            edit { $0.markUnsupported() }
            return
        }
        let generation = (self.generations[token] ?? 0) + 1
        self.generations[token] = generation
        edit { $0.loadState = .running }
        do {
            let result = try await self.request(method, params)
            guard self.generations[token] == generation else { return }
            guard let value = decode(result) else {
                edit { section in
                    section.loadState = .failed(Self.decodeFailure)
                    section.hasLoaded = true
                }
                return
            }
            edit { section in
                section.value = value
                section.supported = true
                section.isForbidden = false
                section.loadState = .idle
                section.hasLoaded = true
            }
        } catch let error where GatewayError.isUnknownMethod(error) {
            guard self.generations[token] == generation else { return }
            edit { $0.markUnsupported() }
        } catch {
            guard self.generations[token] == generation else { return }
            let recovered = recover?(error)
            edit { section in
                if let recovered {
                    section.value = recovered
                    section.loadState = .idle
                } else {
                    section.isForbidden = GatewayError.isForbidden(error)
                    section.loadState = .failed(Self.message(for: error))
                }
                section.hasLoaded = true
            }
        }
    }

    static func message(for error: Error) -> String {
        if error is DecodingError { return Self.decodeFailure }
        if GatewayError.isMissingScope(error) || GatewayError.isUnknownMethod(error) {
            return GatewayError.message(for: error, unavailable: L("usage reports"))
        }
        guard case let GatewayError.rpc(_, message, _) = error else { return error.localizedDescription }
        return message.isEmpty ? L("The Gateway couldn't load usage.") : message
    }
}
