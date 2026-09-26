import Foundation

// MARK: Totals

/// Token and cost totals (`CostUsageTotals`). Missing numbers count as zero; costs are the
/// Gateway's USD estimates, and `missingCostEntries` counts requests it couldn't price.
public struct UsageTotals: Hashable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var totalTokens = 0
    public var totalCost = 0.0
    public var inputCost = 0.0
    public var outputCost = 0.0
    public var cacheReadCost = 0.0
    public var cacheWriteCost = 0.0
    public var missingCostEntries = 0
    /// Unpriced request counts by `provider/model`.
    public var missingCostByModel: [String: Int] = [:]

    public static let zero = UsageTotals()

    public init() {}

    public init(_ json: JSONValue?) {
        guard let json, json.object != nil else { return }
        func int(_ key: String) -> Int { json[key]?.double.map { Int($0.rounded()) } ?? 0 }
        func double(_ key: String) -> Double { json[key]?.double ?? 0 }
        self.input = int("input")
        self.output = int("output")
        self.cacheRead = int("cacheRead")
        self.cacheWrite = int("cacheWrite")
        let sum = self.input + self.output + self.cacheRead + self.cacheWrite
        self.totalTokens = json["totalTokens"]?.double.map { Int($0.rounded()) } ?? json["tokens"]?.double.map { Int($0.rounded()) } ?? sum
        self.totalCost = json["totalCost"]?.double ?? json["cost"]?.double ?? 0
        self.inputCost = double("inputCost")
        self.outputCost = double("outputCost")
        self.cacheReadCost = double("cacheReadCost")
        self.cacheWriteCost = double("cacheWriteCost")
        self.missingCostEntries = int("missingCostEntries")
        self.missingCostByModel = json["missingCostByModel"]?.object?.compactMapValues { $0.int } ?? [:]
    }

    public var cacheTokens: Int { self.cacheRead + self.cacheWrite }
    public var isEmpty: Bool { self.totalTokens == 0 && self.totalCost == 0 && self.missingCostEntries == 0 }
    /// Some priced tokens were split by type (`inputCost`…).
    public var hasCostBreakdown: Bool { self.inputCost + self.outputCost + self.cacheReadCost + self.cacheWriteCost > 0 }

    public var costStatus: UsageCostStatus {
        guard self.missingCostEntries > 0 else { return .known }
        return self.totalCost > 0 ? .partial(missing: self.missingCostEntries) : .unknown(missing: self.missingCostEntries)
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        var sum = lhs
        sum.input += rhs.input
        sum.output += rhs.output
        sum.cacheRead += rhs.cacheRead
        sum.cacheWrite += rhs.cacheWrite
        sum.totalTokens += rhs.totalTokens
        sum.totalCost += rhs.totalCost
        sum.inputCost += rhs.inputCost
        sum.outputCost += rhs.outputCost
        sum.cacheReadCost += rhs.cacheReadCost
        sum.cacheWriteCost += rhs.cacheWriteCost
        sum.missingCostEntries += rhs.missingCostEntries
        sum.missingCostByModel.merge(rhs.missingCostByModel, uniquingKeysWith: +)
        return sum
    }
}

public enum UsageCostStatus: Hashable, Sendable {
    case known
    /// Priced, but `missing` requests had no pricing.
    case partial(missing: Int)
    /// Nothing was priced.
    case unknown(missing: Int)
}

/// Where a cache refresh is (`cacheStatus`): anything but `fresh` means totals may still change.
public struct UsageCacheStatus: Hashable, Sendable {
    public let status: String
    public let pendingFiles: Int
    public let staleFiles: Int

    init?(_ json: JSONValue?) {
        guard let json, let status = json["status"]?.text else { return nil }
        self.status = status
        self.pendingFiles = json["pendingFiles"]?.int ?? 0
        self.staleFiles = json["staleFiles"]?.int ?? 0
    }

    public var isIncomplete: Bool { ["partial", "stale", "refreshing"].contains(self.status) }
}

// MARK: Days

/// One day of usage. Days from `usage.cost` and `aggregates.costDaily` carry every token category;
/// `aggregates.daily` only has total tokens and cost.
public struct UsageDay: Identifiable, Hashable, Sendable {
    /// `YYYY-MM-DD` in the requested zone.
    public let date: String
    public var totals: UsageTotals
    public var hasCategories: Bool
    public var messages: Int?
    public var toolCalls: Int?
    public var errors: Int?

    public var id: String { self.date }

    public init(date: String, totals: UsageTotals = .zero, hasCategories: Bool = true) {
        self.date = date
        self.totals = totals
        self.hasCategories = hasCategories
    }

    init?(_ json: JSONValue) {
        guard let date = json["date"]?.text else { return nil }
        self.date = date
        self.totals = UsageTotals(json)
        self.hasCategories = json["input"] != nil || json["output"] != nil || json["cacheRead"] != nil
        self.messages = json["messages"]?.int
        self.toolCalls = json["toolCalls"]?.int
        self.errors = json["errors"]?.int
    }

    /// Every day of `range`, zero-filled where `days` has none.
    public static func filled(_ days: [UsageDay], range: UsageDateRange) -> [UsageDay] {
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let categories = days.isEmpty || days.contains(where: \.hasCategories)
        return range.dayKeys.map { byDate[$0] ?? UsageDay(date: $0, hasCategories: categories) }
    }
}

// MARK: usage.cost

/// `usage.cost`: daily totals for the range.
public struct CostUsageSummary: Hashable, Sendable {
    public let updatedAt: Date?
    public let days: Int?
    public let daily: [UsageDay]
    public let totals: UsageTotals
    public let cacheStatus: UsageCacheStatus?

    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        self.updatedAt = UsageDates.date(ms: json["updatedAt"])
        self.days = json["days"]?.int
        self.daily = json["daily"]?.array?.compactMap(UsageDay.init) ?? []
        self.totals = json["totals"].map(UsageTotals.init) ?? self.daily.reduce(.zero) { $0 + $1.totals }
        self.cacheStatus = UsageCacheStatus(json["cacheStatus"])
    }
}

// MARK: sessions.usage

public struct UsageMessageCounts: Hashable, Sendable {
    public var total = 0
    public var user = 0
    public var assistant = 0
    public var toolCalls = 0
    public var toolResults = 0
    public var errors = 0

    public init() {}

    init(_ json: JSONValue?) {
        guard let json else { return }
        self.total = json["total"]?.int ?? 0
        self.user = json["user"]?.int ?? 0
        self.assistant = json["assistant"]?.int ?? 0
        self.toolCalls = json["toolCalls"]?.int ?? 0
        self.toolResults = json["toolResults"]?.int ?? 0
        self.errors = json["errors"]?.int ?? 0
        if json["total"] == nil { self.total = self.user + self.assistant }
    }
}

/// One `byModel` / `byProvider` / `modelUsage` bucket.
public struct ModelUsage: Hashable, Sendable {
    public let provider: String?
    public let model: String?
    public let count: Int
    public let totals: UsageTotals

    init(_ json: JSONValue) {
        self.provider = json["provider"]?.text
        self.model = json["model"]?.text
        self.count = json["count"]?.int ?? 0
        self.totals = UsageTotals(json["totals"])
    }
}

/// One `byAgent` / `byChannel` bucket.
public struct KeyedUsage: Hashable, Sendable {
    public let key: String
    public let totals: UsageTotals

    init?(_ json: JSONValue, key field: String) {
        guard json.object != nil else { return nil }
        self.key = json[field]?.text ?? ""
        self.totals = UsageTotals(json["totals"])
    }
}

/// A session's usage in the range (`SessionCostSummary`).
public struct SessionUsageSummary: Hashable, Sendable {
    public let totals: UsageTotals
    public let firstActivity: Date?
    public let lastActivity: Date?
    public let durationMs: Double?
    public let messageCounts: UsageMessageCounts?
    public let toolCalls: Int?
    public let modelUsage: [ModelUsage]

    init?(_ json: JSONValue?) {
        guard let json, json.object != nil else { return nil }
        self.totals = UsageTotals(json)
        self.firstActivity = UsageDates.date(ms: json["firstActivity"])
        self.lastActivity = UsageDates.date(ms: json["lastActivity"])
        self.durationMs = json["durationMs"]?.double
        self.messageCounts = json["messageCounts"].map(UsageMessageCounts.init)
        self.toolCalls = json["toolUsage"]?["totalCalls"]?.int
        self.modelUsage = json["modelUsage"]?.array?.map(ModelUsage.init) ?? []
    }
}

/// One row of `sessions.usage` (`SessionUsageEntry`). `usage` is nil while the Gateway is
/// still computing it.
public struct SessionUsageRow: Identifiable, Hashable, Sendable {
    public let key: String
    public let label: String?
    public let sessionId: String?
    public let updatedAt: Date?
    public let agentId: String?
    public let channel: String?
    public let provider: String?
    public let model: String?
    public let usage: SessionUsageSummary?
    public let computing: Bool

    public var id: String { self.key }

    init?(_ json: JSONValue) {
        guard let key = json["key"]?.text else { return nil }
        self.key = key
        self.label = json["label"]?.text
        self.sessionId = json["sessionId"]?.text
        self.updatedAt = UsageDates.date(ms: json["updatedAt"])
        self.agentId = json["agentId"]?.text ?? SessionKey.agentId(from: key)
        self.channel = json["channel"]?.text
        self.provider = json["providerOverride"]?.text ?? json["modelProvider"]?.text
        self.model = json["modelOverride"]?.text ?? json["model"]?.text
        self.usage = SessionUsageSummary(json["usage"])
        self.computing = json["computing"]?.bool == true || self.usage == nil
    }

    /// Latest activity: the usage's last activity, else the row's `updatedAt`.
    public var lastActive: Date? { self.usage?.lastActivity ?? self.updatedAt }
}

public struct SessionsUsageAggregates: Hashable, Sendable {
    public var sessionCount: Int?
    public var messages = UsageMessageCounts()
    public var toolCalls = 0
    public var byModel: [ModelUsage] = []
    public var byProvider: [ModelUsage] = []
    public var byAgent: [KeyedUsage] = []
    public var byChannel: [KeyedUsage] = []
    public var daily: [UsageDay] = []
    public var costDaily: [UsageDay]?

    init(_ json: JSONValue?) {
        guard let json, json.object != nil else { return }
        self.sessionCount = json["sessionCount"]?.int
        self.messages = UsageMessageCounts(json["messages"])
        self.toolCalls = json["tools"]?["totalCalls"]?.int ?? self.messages.toolCalls
        self.byModel = json["byModel"]?.array?.map(ModelUsage.init) ?? []
        self.byProvider = json["byProvider"]?.array?.map(ModelUsage.init) ?? []
        self.byAgent = json["byAgent"]?.array?.compactMap { KeyedUsage($0, key: "agentId") } ?? []
        self.byChannel = json["byChannel"]?.array?.compactMap { KeyedUsage($0, key: "channel") } ?? []
        self.daily = json["daily"]?.array?.compactMap(UsageDay.init).map { day in
            var day = day
            day.hasCategories = false
            return day
        } ?? []
        self.costDaily = json["costDaily"]?.array?.compactMap(UsageDay.init)
    }
}

/// `sessions.usage`: per-session rows (capped by `limit`) and aggregates over every matched session.
public struct SessionsUsageResult: Hashable, Sendable {
    public let updatedAt: Date?
    public let startDate: String?
    public let endDate: String?
    public let sessions: [SessionUsageRow]
    public let totals: UsageTotals
    public let aggregates: SessionsUsageAggregates
    public let cacheStatus: UsageCacheStatus?

    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        self.updatedAt = UsageDates.date(ms: json["updatedAt"])
        self.startDate = json["startDate"]?.text
        self.endDate = json["endDate"]?.text
        self.sessions = json["sessions"]?.array?.compactMap(SessionUsageRow.init) ?? []
        self.totals = json["totals"].map(UsageTotals.init)
            ?? self.sessions.reduce(.zero) { $0 + ($1.usage?.totals ?? .zero) }
        self.aggregates = SessionsUsageAggregates(json["aggregates"])
        self.cacheStatus = UsageCacheStatus(json["cacheStatus"])
    }

    /// Every matched session, not just the rows returned.
    public var sessionCount: Int { self.aggregates.sessionCount ?? self.sessions.count }
}

// MARK: usage.status

public struct UsageWindow: Hashable, Sendable {
    public let label: String
    public let groupLabel: String?
    public let usedPercent: Double
    public let resetAt: Date?

    init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        self.label = json["label"]?.text ?? "Usage"
        self.groupLabel = json["groupLabel"]?.text
        self.usedPercent = json["usedPercent"]?.double ?? 0
        self.resetAt = UsageDates.date(ms: json["resetAt"])
    }

    /// "Weekly · Opus": the group, then the window.
    public var title: String { self.groupLabel.map { "\($0) · \(self.label)" } ?? self.label }
}

/// A provider-reported balance, spend or budget. Units may be currencies or credits.
public struct UsageBilling: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case balance
        case spend
        case budget
        case other(String)
    }

    public let kind: Kind
    public let label: String?
    public let amount: Double?
    public let used: Double?
    public let limit: Double?
    public let unit: String
    public let period: String?
    public let resetAt: Date?

    init?(_ json: JSONValue) {
        guard let type = json["type"]?.text else { return nil }
        switch type {
        case "balance": self.kind = .balance
        case "spend": self.kind = .spend
        case "budget": self.kind = .budget
        default: self.kind = .other(type)
        }
        self.label = json["label"]?.text
        self.amount = json["amount"]?.double
        self.used = json["used"]?.double
        self.limit = json["limit"]?.double
        self.unit = json["unit"]?.text ?? ""
        self.period = json["period"]?.text
        self.resetAt = UsageDates.date(ms: json["resetAt"])
    }

    public var title: String {
        if let label { return label }
        switch self.kind {
        case .balance: return "Balance"
        case .spend: return "Spend"
        case .budget: return "Budget"
        case let .other(raw): return raw.capitalized
        }
    }
}

public struct ProviderUsage: Identifiable, Hashable, Sendable {
    public let provider: String
    public let displayName: String
    public let windows: [UsageWindow]
    public let billing: [UsageBilling]
    public let summary: String?
    public let plan: String?
    public let accountEmail: String?
    public let error: String?

    public var id: String { self.provider }

    init?(_ json: JSONValue) {
        guard json.object != nil, let provider = json["provider"]?.text ?? json["displayName"]?.text else { return nil }
        self.provider = provider
        self.displayName = json["displayName"]?.text ?? provider.capitalized
        self.windows = json["windows"]?.array?.compactMap(UsageWindow.init) ?? []
        self.billing = json["billing"]?.array?.compactMap(UsageBilling.init) ?? []
        self.summary = json["summary"]?.text
        self.plan = json["plan"]?.text
        self.accountEmail = json["accountEmail"]?.text
        self.error = json["error"]?.text
    }
}

/// `usage.status`: provider quotas and billing, independent of any date range.
public struct UsageStatusSummary: Hashable, Sendable {
    public let updatedAt: Date?
    public let providers: [ProviderUsage]
    /// A background refresh owns the real values; an empty list is incomplete.
    public let refreshing: Bool

    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        self.updatedAt = UsageDates.date(ms: json["updatedAt"])
        self.providers = json["providers"]?.array?.compactMap(ProviderUsage.init) ?? []
        self.refreshing = json["refreshing"]?.bool == true
    }
}

// MARK: Session detail

/// One point of `sessions.usage.timeseries`, over the whole session.
public struct UsagePoint: Identifiable, Hashable, Sendable {
    public let index: Int
    public let timestamp: Date
    public let totals: UsageTotals
    public let cumulativeTokens: Int
    public let cumulativeCost: Double

    public var id: Int { self.index }

    init?(_ json: JSONValue, index: Int) {
        guard let timestamp = UsageDates.date(ms: json["timestamp"]) else { return nil }
        self.index = index
        self.timestamp = timestamp
        self.totals = UsageTotals(json)
        self.cumulativeTokens = json["cumulativeTokens"]?.int ?? 0
        self.cumulativeCost = json["cumulativeCost"]?.double ?? 0
    }
}

public struct UsageTimeSeries: Hashable, Sendable {
    public let sessionId: String?
    public let points: [UsagePoint]

    public static let empty = UsageTimeSeries(sessionId: nil, points: [])

    init(sessionId: String?, points: [UsagePoint]) {
        self.sessionId = sessionId
        self.points = points
    }

    public init?(_ json: JSONValue) {
        if json.isNull {
            self = .empty
            return
        }
        guard json.object != nil else { return nil }
        self.sessionId = json["sessionId"]?.text
        let raw = json["points"]?.array ?? []
        self.points = raw.enumerated().compactMap { UsagePoint($1, index: $0) }.sorted { $0.timestamp < $1.timestamp }
    }
}

/// One entry of `sessions.usage.logs`. Content is plain text.
public struct UsageLogEntry: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case user
        case assistant
        case tool
        case toolResult
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "user": self = .user
            case "assistant": self = .assistant
            case "tool": self = .tool
            case "toolResult", "tool_result": self = .toolResult
            default: self = .other(raw ?? "unknown")
            }
        }

        public var label: String {
            switch self {
            case .user: "User"
            case .assistant: "Assistant"
            case .tool: "Tool call"
            case .toolResult: "Tool result"
            case let .other(raw): raw.capitalized
            }
        }
    }

    public let index: Int
    public let timestamp: Date?
    public let role: Role
    public let content: String
    public let tokens: Int?
    public let cost: Double?

    public var id: Int { self.index }

    init?(_ json: JSONValue, index: Int) {
        guard json.object != nil else { return nil }
        self.index = index
        self.timestamp = UsageDates.date(ms: json["timestamp"])
        self.role = Role(json["role"]?.string)
        self.content = json["content"]?.string ?? json["content"].map { $0.compactString() } ?? ""
        self.tokens = json["tokens"]?.int
        self.cost = json["cost"]?.double
    }

    /// Newest first; entries without a timestamp keep their order at the end.
    static func decode(_ json: JSONValue) -> [UsageLogEntry]? {
        guard let raw = json["logs"]?.array ?? json.array else { return json.object != nil ? [] : nil }
        let entries = raw.enumerated().compactMap { UsageLogEntry($1, index: $0) }
        return entries.sorted { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?): l == r ? lhs.index > rhs.index : l > r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.index < rhs.index
            }
        }
    }
}

// MARK: Dates

/// Presets for the usage range. Ranges end today and include it.
public enum UsageRangePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case today
    case week
    case month
    case quarter
    case custom

    public var id: String { self.rawValue }

    public var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .quarter: "90 Days"
        case .custom: "Custom"
        }
    }

    public var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .custom: nil
        }
    }
}

/// An inclusive range of local calendar days.
public struct UsageDateRange: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let calendar: Calendar

    /// Days from `start` to `end`, both included; an end before the start is moved to the start.
    public init(start: Date, end: Date, calendar: Calendar = UsageDates.calendar()) {
        let start = calendar.startOfDay(for: start)
        self.start = start
        self.end = max(start, calendar.startOfDay(for: end))
        self.calendar = calendar
    }

    /// The last `days` days, today included.
    public static func last(_ days: Int, now: Date = Date(), calendar: Calendar = UsageDates.calendar()) -> UsageDateRange {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: end) ?? end
        return UsageDateRange(start: start, end: end, calendar: calendar)
    }

    public var startKey: String { UsageDates.key(self.start, calendar: self.calendar) }
    public var endKey: String { UsageDates.key(self.end, calendar: self.calendar) }

    public var dayKeys: [String] {
        var keys: [String] = []
        var day = self.start
        while day <= self.end, keys.count < 3660 {
            keys.append(UsageDates.key(day, calendar: self.calendar))
            guard let next = self.calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }
}

/// The range picker's state: a preset, or custom days.
public struct UsageRangeSelection: Hashable, Sendable {
    public var preset: UsageRangePreset
    public var customStart: Date
    public var customEnd: Date

    public init(preset: UsageRangePreset = .week, now: Date = Date()) {
        self.preset = preset
        let week = UsageDateRange.last(7, now: now)
        self.customStart = week.start
        self.customEnd = week.end
    }

    public func range(now: Date = Date(), calendar: Calendar = UsageDates.calendar()) -> UsageDateRange {
        if let days = self.preset.days { return .last(days, now: now, calendar: calendar) }
        let today = calendar.startOfDay(for: now)
        let end = min(calendar.startOfDay(for: self.customEnd), today)
        let start = min(calendar.startOfDay(for: self.customStart), end)
        return UsageDateRange(start: start, end: end, calendar: calendar)
    }
}

public enum UsageDates {
    /// Gregorian in the device's time zone, whatever calendar the user reads dates in:
    /// the Gateway's keys are `YYYY-MM-DD`.
    public static func calendar(_ timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `YYYY-MM-DD` of the local day containing `date`.
    public static func key(_ date: Date, calendar: Calendar = UsageDates.calendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The local midnight starting a `YYYY-MM-DD` day, never shifted through UTC.
    public static func date(fromKey key: String, calendar: Calendar = UsageDates.calendar()) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// `UTC+5:30`, `UTC-8`, `UTC+0`, like the Control UI's `formatUtcOffset`.
    public static func utcOffset(secondsFromGMT seconds: Int) -> String {
        let minutes = seconds / 60
        let sign = minutes >= 0 ? "+" : "-"
        let hours = abs(minutes) / 60
        let rest = abs(minutes) % 60
        return rest == 0 ? "UTC\(sign)\(hours)" : String(format: "UTC%@%d:%02d", sign, hours, rest)
    }

    /// `startDate`, `endDate`, `mode: "specific"`, `timeZone` and `utcOffset` for a range.
    public static func params(_ range: UsageDateRange, at now: Date = Date()) -> [String: JSONValue] {
        let zone = range.calendar.timeZone
        return [
            "startDate": .string(range.startKey),
            "endDate": .string(range.endKey),
            "mode": "specific",
            "timeZone": .string(zone.identifier),
            "utcOffset": .string(Self.utcOffset(secondsFromGMT: zone.secondsFromGMT(for: now))),
        ]
    }

    static func date(ms value: JSONValue?) -> Date? {
        guard let ms = value?.double, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// Request params for the usage methods.
public enum UsageRequests {
    /// Rows `sessions.usage` returns for the dashboard; aggregates cover every session regardless.
    public static let sessionLimit = 200
    public static let logLimit = 200

    public static func cost(_ range: UsageDateRange, at now: Date = Date()) -> JSONValue {
        var params = UsageDates.params(range, at: now)
        params["agentScope"] = "all"
        return .object(params)
    }

    public static func sessions(_ range: UsageDateRange, limit: Int = UsageRequests.sessionLimit, at now: Date = Date()) -> JSONValue {
        var params = UsageDates.params(range, at: now)
        params["agentScope"] = "all"
        params["groupBy"] = "instance"
        params["limit"] = JSONValue(max(1, min(1000, limit)))
        params["includeContextWeight"] = false
        return .object(params)
    }

    /// One session: `key` (and its agent), never `agentScope`.
    public static func session(key: String, agentId: String?, range: UsageDateRange, at now: Date = Date()) -> JSONValue {
        var params = UsageDates.params(range, at: now)
        params["key"] = .string(key)
        if let agentId = agentId ?? SessionKey.agentId(from: key) { params["agentId"] = .string(agentId) }
        params["groupBy"] = "instance"
        params["limit"] = 1
        params["includeContextWeight"] = false
        return .object(params)
    }

    public static func timeseries(key: String, agentId: String?) -> JSONValue {
        var params: [String: JSONValue] = ["key": .string(key)]
        if let agentId = agentId ?? SessionKey.agentId(from: key) { params["agentId"] = .string(agentId) }
        return .object(params)
    }

    public static func logs(key: String, agentId: String?, limit: Int = UsageRequests.logLimit) -> JSONValue {
        var params = self.timeseries(key: key, agentId: agentId).object ?? [:]
        params["limit"] = JSONValue(max(1, min(1000, limit)))
        return .object(params)
    }
}

// MARK: Formatting

public enum UsageFormat {
    /// `950`, `12.3k`, `1.2M`, `3.4B`.
    public static func tokens(_ count: Int) -> String { TokenCount.format(count) }

    /// "12,345 tokens", for VoiceOver.
    public static func tokensSpoken(_ count: Int, locale: Locale = .current) -> String {
        "\(count.formatted(.number.locale(locale))) \(count == 1 ? "token" : "tokens")"
    }

    /// USD: `$0.00`, `<$0.01`, `$12.34`, `$1,234`, `$123K`.
    public static func currency(_ value: Double, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale)
        let magnitude = abs(value)
        if magnitude == 0 { return 0.0.formatted(style.precision(.fractionLength(2))) }
        if magnitude < 0.01 { return "<" + 0.01.formatted(style.precision(.fractionLength(2))) }
        if magnitude < 100 { return value.formatted(style.precision(.fractionLength(2))) }
        if magnitude < 100_000 { return value.formatted(style.precision(.fractionLength(0))) }
        return value.formatted(style.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// Compact USD for chart axes: `$0`, `$1.2`, `$45`, `$1.2K`.
    public static func axisCurrency(_ value: Double, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale)
        if value == 0 { return 0.0.formatted(style.precision(.fractionLength(0))) }
        if abs(value) < 10 { return value.formatted(style.precision(.fractionLength(0...2))) }
        return value.formatted(style.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// How a cost reads, with unknown and partial pricing spelled out.
    public struct Cost: Hashable, Sendable {
        /// "$12.34", "$12.34*" (partial) or "—" (unknown).
        public let text: String
        /// The amount alone, without the partial marker.
        public let amount: String?
        public let status: UsageCostStatus
        /// "Excludes 3 requests without pricing", or the unknown-cost explanation.
        public let note: String?
        public let accessibilityLabel: String
    }

    public static let unknownCostHelp = "The provider didn't report pricing for these requests."

    public static func cost(_ totals: UsageTotals, locale: Locale = .current) -> Cost {
        let amount = self.currency(totals.totalCost, locale: locale)
        switch totals.costStatus {
        case .known:
            return Cost(text: amount, amount: amount, status: .known, note: nil, accessibilityLabel: amount)
        case let .partial(missing):
            let note = self.excludesNote(missing)
            return Cost(text: amount + "*", amount: amount, status: .partial(missing: missing), note: note,
                        accessibilityLabel: "\(amount), \(note.prefix(1).lowercased() + note.dropFirst())")
        case let .unknown(missing):
            return Cost(text: "—", amount: nil, status: .unknown(missing: missing), note: self.unknownCostHelp,
                        accessibilityLabel: "Cost unknown")
        }
    }

    public static func excludesNote(_ missing: Int) -> String {
        "Excludes \(missing) request\(missing == 1 ? "" : "s") without pricing"
    }

    /// `82%`; above 100 reads `100%+`.
    public static func percent(_ used: Double) -> String {
        guard used.isFinite else { return "0%" }
        if used > 100 { return "100%+" }
        return "\(Int(max(0, used).rounded()))%"
    }

    /// 0…1 for a gauge.
    public static func fraction(_ used: Double) -> Double {
        guard used.isFinite else { return 0 }
        return min(max(used, 0), 100) / 100
    }

    /// "Resets in 2h 14m" within a day, else "Resets Sep 27, 9:00 AM".
    public static func reset(_ date: Date, now: Date = Date(), locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String
    {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Resets soon" }
        if seconds < 86400 { return "Resets in \(self.shortDuration(seconds))" }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        style = style.year(.omitted)
        return "Resets \(date.formatted(style))"
    }

    /// "resets in 2 hours" / "resets September 27 at 9:00 AM", for VoiceOver.
    public static func resetSpoken(_ date: Date, now: Date = Date(), locale: Locale = .current,
                                   timeZone: TimeZone = .current) -> String
    {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resets soon" }
        if seconds < 86400 {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            if hours > 0 { return "resets in \(hours) hour\(hours == 1 ? "" : "s")" }
            return "resets in \(max(1, minutes)) minute\(minutes == 1 ? "" : "s")"
        }
        return "resets \(date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: timeZone)))"
    }

    /// `2h 14m`, `45m`, `<1m`, `3d 4h`.
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }

    /// "Sep 20 – Sep 26" (or "Sep 26" for one day) from `YYYY-MM-DD` keys.
    public static func range(start: String, end: String, locale: Locale = .current,
                             calendar: Calendar = UsageDates.calendar()) -> String?
    {
        guard let from = UsageDates.date(fromKey: start, calendar: calendar),
              let to = UsageDates.date(fromKey: end, calendar: calendar) else { return nil }
        let sameYear = calendar.component(.year, from: from) == calendar.component(.year, from: to)
            && calendar.component(.year, from: to) == calendar.component(.year, from: Date())
        let style = self.dayStyle(locale: locale, calendar: calendar, year: !sameYear)
        if start == end { return from.formatted(style) }
        return "\(from.formatted(style)) – \(to.formatted(style))"
    }

    /// "Sep 24" for a `YYYY-MM-DD` key.
    public static func day(_ key: String, locale: Locale = .current, calendar: Calendar = UsageDates.calendar()) -> String {
        guard let date = UsageDates.date(fromKey: key, calendar: calendar) else { return key }
        return date.formatted(self.dayStyle(locale: locale, calendar: calendar, year: false))
    }

    private static func dayStyle(locale: Locale, calendar: Calendar, year: Bool) -> Date.FormatStyle {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if year { style = style.year() }
        return style
    }

    /// Unit amounts: currency when `unit` is an ISO 4217 code, else "1,200 credits".
    public static func amount(_ value: Double, unit: String, locale: Locale = .current) -> String {
        let code = unit.uppercased()
        if code.count == 3, Locale.Currency.isoCurrencies.contains(Locale.Currency(code)) {
            if code == "USD" { return self.currency(value, locale: locale) }
            return value.formatted(.currency(code: code).locale(locale))
        }
        let number = value.formatted(.number.locale(locale).precision(.fractionLength(0...2)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// "1h 12m" for a session's duration.
    public static func duration(ms: Double) -> String {
        self.shortDuration(ms / 1000)
    }

    /// "agent:main:dashboard:0123456789abcdef" → "agent:main:dash…89abcdef".
    public static func middleTruncated(_ text: String, limit: Int = 32) -> String {
        guard text.count > limit, limit > 3 else { return text }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return "\(text.prefix(head))…\(text.suffix(tail))"
    }
}

// MARK: Sorting and levels

/// How the sessions table sorts. Rows still being computed always sort last.
public enum UsageSessionSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cost
    case tokens
    case recent

    public var id: String { self.rawValue }

    public var label: String {
        switch self {
        case .cost: "Cost"
        case .tokens: "Tokens"
        case .recent: "Recent"
        }
    }

    public func sorted(_ rows: [SessionUsageRow], ascending: Bool = false) -> [SessionUsageRow] {
        rows.enumerated().sorted { lhs, rhs in
            let (l, r) = (lhs.element, rhs.element)
            if (l.usage == nil) != (r.usage == nil) { return r.usage == nil }
            let order: (Double, Double) = switch self {
            case .cost: (l.usage?.totals.totalCost ?? 0, r.usage?.totals.totalCost ?? 0)
            case .tokens: (Double(l.usage?.totals.totalTokens ?? 0), Double(r.usage?.totals.totalTokens ?? 0))
            case .recent: (l.lastActive?.timeIntervalSince1970 ?? 0, r.lastActive?.timeIntervalSince1970 ?? 0)
            }
            if order.0 != order.1 { return ascending ? order.0 < order.1 : order.0 > order.1 }
            if self == .cost, let lt = l.usage?.totals.totalTokens, let rt = r.usage?.totals.totalTokens, lt != rt {
                return ascending ? lt < rt : lt > rt
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }
}

/// How close a quota window is to its limit: warning from 75%, critical from 90%.
public enum UsageLevel: Hashable, Sendable {
    case normal
    case warning
    case critical

    public init(usedPercent: Double) {
        if usedPercent >= 90 { self = .critical } else if usedPercent >= 75 { self = .warning } else { self = .normal }
    }
}

/// Top buckets for a breakdown chart; the rest summed as "Other".
public struct UsageBreakdownItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let totals: UsageTotals
    public let isOther: Bool

    public init(id: String, title: String, subtitle: String? = nil, totals: UsageTotals, isOther: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.totals = totals
        self.isOther = isOther
    }

    /// Sorted descending by cost (or tokens), the first `limit` kept and the rest folded into "Other".
    public static func top(_ items: [UsageBreakdownItem], byCost: Bool, limit: Int = 8) -> [UsageBreakdownItem] {
        let sorted = items.sorted { lhs, rhs in
            let (l, r) = byCost ? (lhs.totals.totalCost, rhs.totals.totalCost)
                : (Double(lhs.totals.totalTokens), Double(rhs.totals.totalTokens))
            return l == r ? lhs.totals.totalTokens > rhs.totals.totalTokens : l > r
        }
        guard sorted.count > limit else { return sorted }
        let rest = sorted.dropFirst(limit).reduce(UsageTotals.zero) { $0 + $1.totals }
        return Array(sorted.prefix(limit)) + [UsageBreakdownItem(id: "__other__", title: "Other", totals: rest, isOther: true)]
    }
}

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
    public nonisolated static let decodeFailure = "The gateway sent usage data Pincer couldn't read."

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
    /// the first time or when `includeStatus` asks (Refresh). A forbidden `usage.cost` waits
    /// for an explicit refresh.
    public func load(includeStatus: Bool = false, force: Bool = false) async {
        let reloadStatus = includeStatus || !self.status.hasLoaded
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
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
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
                    section.isForbidden = Self.isForbidden(error)
                    section.loadState = .failed(Self.message(for: error))
                }
                section.hasLoaded = true
            }
        }
    }

    static func isForbidden(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, _, details) = error else { return false }
        return code == "FORBIDDEN" && details?["code"]?.text != "MISSING_SCOPE"
    }

    static func message(for error: Error) -> String {
        if error is DecodingError { return Self.decodeFailure }
        guard case let GatewayError.rpc(_, message, _) = error else { return error.localizedDescription }
        return message.isEmpty ? "The gateway couldn't load usage." : message
    }
}
