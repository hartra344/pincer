import Foundation

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
        return "\(Int(saturating: max(0, used)) ?? 0)%"
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
            let minutes = max(1, (Int(seconds) % 3600) / 60)
            if hours > 0 { return "resets in \(hours) hour\(hours == 1 ? "" : "s")" }
            return "resets in \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "resets \(date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: timeZone)))"
    }

    /// `2h 14m`, `45m`, `<1m`, `3d 4h`.
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(saturating: seconds, rounding: .towardZero) ?? 0
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
