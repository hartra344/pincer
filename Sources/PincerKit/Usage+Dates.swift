import Foundation

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
