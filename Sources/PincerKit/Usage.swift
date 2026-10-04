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
        func int(_ key: String) -> Int { Self.count(json[key]?.double) }
        func double(_ key: String) -> Double { json[key]?.double ?? 0 }
        self.input = int("input")
        self.output = int("output")
        self.cacheRead = int("cacheRead")
        self.cacheWrite = int("cacheWrite")
        let sum = Self.add(Self.add(self.input, self.output), Self.add(self.cacheRead, self.cacheWrite))
        self.totalTokens = json["totalTokens"]?.double.map { Self.count($0) } ?? json["tokens"]?.double.map { Self.count($0) } ?? sum
        self.totalCost = json["totalCost"]?.double ?? json["cost"]?.double ?? 0
        self.inputCost = double("inputCost")
        self.outputCost = double("outputCost")
        self.cacheReadCost = double("cacheReadCost")
        self.cacheWriteCost = double("cacheWriteCost")
        self.missingCostEntries = int("missingCostEntries")
        self.missingCostByModel = json["missingCostByModel"]?.object?.compactMapValues { $0.double.map { Self.count($0) } } ?? [:]
    }

    private static func count(_ value: Double?) -> Int {
        guard let value, value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        guard rounded < Double(Int.max) else { return Int.max }
        return Int(rounded)
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? Int.max : sum
    }

    public var cacheTokens: Int { Self.add(self.cacheRead, self.cacheWrite) }
    public var isEmpty: Bool { self.totalTokens == 0 && self.totalCost == 0 && self.missingCostEntries == 0 }
    /// Some priced tokens were split by type (`inputCost`…).
    public var hasCostBreakdown: Bool { self.inputCost + self.outputCost + self.cacheReadCost + self.cacheWriteCost > 0 }

    public var costStatus: UsageCostStatus {
        guard self.missingCostEntries > 0 else { return .known }
        return self.totalCost > 0 ? .partial(missing: self.missingCostEntries) : .unknown(missing: self.missingCostEntries)
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        var sum = lhs
        sum.input = Self.add(lhs.input, rhs.input)
        sum.output = Self.add(lhs.output, rhs.output)
        sum.cacheRead = Self.add(lhs.cacheRead, rhs.cacheRead)
        sum.cacheWrite = Self.add(lhs.cacheWrite, rhs.cacheWrite)
        sum.totalTokens = Self.add(lhs.totalTokens, rhs.totalTokens)
        sum.totalCost += rhs.totalCost
        sum.inputCost += rhs.inputCost
        sum.outputCost += rhs.outputCost
        sum.cacheReadCost += rhs.cacheReadCost
        sum.cacheWriteCost += rhs.cacheWriteCost
        sum.missingCostEntries = Self.add(lhs.missingCostEntries, rhs.missingCostEntries)
        sum.missingCostByModel.merge(rhs.missingCostByModel, uniquingKeysWith: Self.add)
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
