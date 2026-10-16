import Foundation

/// What the Usage page can export (#984), as in the Control UI's Export menu.
public enum UsageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case sessionsCSV
    case dailyCSV
    case json

    public var id: String { self.rawValue }

    public var label: String {
        switch self {
        case .sessionsCSV: L("Sessions CSV")
        case .dailyCSV: L("Daily CSV")
        case .json: L("JSON")
        }
    }
}

/// A built export, ready for a save panel or share sheet.
public struct UsageExportFile: Sendable, Hashable {
    public let name: String
    public let data: Data
    public let format: UsageExportFormat

    public init(name: String, data: Data, format: UsageExportFormat) {
        self.name = name
        self.data = data
        self.format = format
    }
}

public enum UsageExportError: Error, Equatable, Sendable {
    /// The Gateway is still counting some sessions (`cacheStatus` isn't `fresh`, and
    /// `overview.selectedUsageComplete` doesn't vouch for the selection).
    case incomplete
    /// The reply wasn't a `sessions.usage` result.
    case unreadable
    /// The Gateway doesn't have `sessions.usage`.
    case unsupported
    /// The reply has no `aggregates.costDaily`, so there's nothing for the daily CSV.
    case noDaily
    case failed(String)

    public var message: String {
        switch self {
        case .incomplete: L("Usage data is incomplete. Refresh usage and try again, or narrow the date range.")
        case .unreadable: UsageModel.decodeFailure
        case .unsupported: L("This Gateway doesn't report usage by session.")
        case .noDaily: L("This Gateway doesn't report daily usage. Update OpenClaw to export it.")
        case let .failed(message): message
        }
    }
}

#if DEBUG
/// Records where export builds ran, so checks can prove they stay off the main thread.
package final class UsageExportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0, worker = 0
    package init() {}
    func record() {
        self.lock.lock(); defer { self.lock.unlock() }
        if Thread.isMainThread { self.main += 1 } else { self.worker += 1 }
    }
    package func snapshot() -> (main: Int, worker: Int) {
        self.lock.lock(); defer { self.lock.unlock() }
        return (self.main, self.worker)
    }
}
#endif

/// Builds Usage exports from a raw `sessions.usage` reply, matching the Control UI's
/// (`ui/src/pages/usage/export.ts`, `query.ts`): same columns, escaping and file names.
/// Works on the raw JSON so the JSON export keeps every field the Gateway sent.
public enum UsageExport {
    /// Rows asked for when every session is wanted. The Control UI sends `MAX_SAFE_INTEGER`;
    /// the schema only sets a minimum of 1.
    public static let sessionLimit = 100_000

    static let sessionColumns = ["key", "label", "agentId", "channel", "provider", "model", "updatedAt", "durationMs",
                                 "messages", "errors", "toolCalls", "inputTokens", "outputTokens", "cacheReadTokens",
                                 "cacheWriteTokens", "totalTokens", "totalCost"]
    static let dailyColumns = ["date", "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "totalTokens",
                               "inputCost", "outputCost", "cacheReadCost", "cacheWriteCost", "totalCost"]

    /// `sessions.usage` params for an export of the page's range: every agent, every row
    /// (one for the daily CSV, whose days cover every session regardless), context weight for JSON.
    public static func params(_ format: UsageExportFormat, range: UsageDateRange, at now: Date = Date()) -> JSONValue {
        var params = UsageDates.params(range, at: now)
        params["agentScope"] = "all"
        params["groupBy"] = "instance"
        params["limit"] = JSONValue(format == .dailyCSV ? 1 : self.sessionLimit)
        params["includeContextWeight"] = .bool(format == .json)
        return .object(params)
    }

    /// `openclaw-usage-sessions-2026-10-16.csv`, `openclaw-usage-daily-….csv`, `openclaw-usage-….json`,
    /// stamped with the local day of `date`.
    public static func fileName(_ format: UsageExportFormat, date: Date, calendar: Calendar = UsageDates.calendar()) -> String {
        let stamp = UsageDates.key(date, calendar: calendar)
        switch format {
        case .sessionsCSV: return "openclaw-usage-sessions-\(stamp).csv"
        case .dailyCSV: return "openclaw-usage-daily-\(stamp).csv"
        case .json: return "openclaw-usage-\(stamp).json"
        }
    }

    /// Builds the file. Call it off the main thread: it walks and encodes every row.
    public static func build(_ format: UsageExportFormat, result: JSONValue, date: Date,
                             calendar: Calendar = UsageDates.calendar()) throws(UsageExportError) -> UsageExportFile {
        guard result.object != nil, let sessions = result["sessions"]?.array else { throw .unreadable }
        if let cache = result["cacheStatus"]?.object, cache["status"]?.string != "fresh",
           result["overview"]?["selectedUsageComplete"]?.bool != true
        {
            throw .incomplete
        }
        // Upstream saves a header-only file; a Gateway without daily figures gets an error instead.
        if format == .dailyCSV, result["aggregates"]?["costDaily"]?.array == nil { throw .noDaily }
        let data: Data = switch format {
        case .sessionsCSV: Data(self.sessionsCSV(sessions).utf8)
        case .dailyCSV: Data(self.dailyCSV(self.daily(result)).utf8)
        case .json: self.json(result)
        }
        return UsageExportFile(name: self.fileName(format, date: date, calendar: calendar), data: data, format: format)
    }

    public static func sessionsCSV(_ sessions: [JSONValue]) -> String {
        self.csv(sessions, columns: self.sessionColumns) { session in
            let usage = session["usage"]
            let counts = usage?["messageCounts"]
            let unavailable = self.isUnavailable(usage)
            let tokens: (String) -> JSONValue? = { unavailable ? nil : usage?[$0] }
            return [
                session["key"], session["label"], session["agentId"], session["channel"],
                self.present(session["modelProvider"]) ?? session["providerOverride"],
                self.present(session["model"]) ?? session["modelOverride"],
                self.isoTimestamp(session["updatedAt"]).map(JSONValue.string),
                usage?["durationMs"], counts?["total"], counts?["errors"], counts?["toolCalls"],
                tokens("input"), tokens("output"), tokens("cacheRead"), tokens("cacheWrite"),
                tokens("totalTokens"), tokens("totalCost"),
            ]
        }
    }

    public static func dailyCSV(_ daily: [JSONValue]) -> String {
        self.csv(daily, columns: self.dailyColumns) { day in
            let unavailable = self.isUnavailable(day)
            let value: (String) -> JSONValue? = { unavailable ? nil : day[$0] }
            return [day["date"], value("input"), value("output"), value("cacheRead"), value("cacheWrite"), value("totalTokens"),
                    value("inputCost"), value("outputCost"), value("cacheReadCost"), value("cacheWriteCost"), value("totalCost")]
        }
    }

    /// `{ sessions, totals, aggregates, daily }`, pretty-printed with sorted keys; `daily` is
    /// `aggregates.costDaily` (or empty).
    public static func json(_ result: JSONValue) -> Data {
        let export: JSONValue = [
            "sessions": result["sessions"] ?? .array([]),
            "totals": result["totals"] ?? .null,
            "aggregates": result["aggregates"] ?? .null,
            "daily": .array(self.daily(result)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(export)) ?? Data()
    }

    // MARK: CSV

    private static func daily(_ result: JSONValue) -> [JSONValue] {
        result["aggregates"]?["costDaily"]?.array ?? []
    }

    private static func csv(_ entries: [JSONValue], columns: [String], row: (JSONValue) -> [JSONValue?]) -> String {
        var lines = [columns.map { self.csvCell(.string($0)) }.joined(separator: ",")]
        lines.reserveCapacity(entries.count + 1)
        for entry in entries {
            lines.append(row(entry).map(self.csvCell).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// A numeric cell is blank when its source says usage is unavailable (only subtotals known).
    private static func isUnavailable(_ value: JSONValue?) -> Bool {
        value?["usageReport"]?["state"]?.string == "unavailable"
    }

    /// The value unless it's missing or null, for `??` fallbacks like the Control UI's.
    private static func present(_ value: JSONValue?) -> JSONValue? {
        guard let value, !value.isNull else { return nil }
        return value
    }

    /// One cell: strings neutralized against spreadsheet formulas and quoted when needed;
    /// numbers as JavaScript prints them; missing or null blank.
    static func csvCell(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: return ""
        case let .string(text)?: return self.escape(text, neutralizeFormulas: true)
        case let .number(number)?: return self.escape(self.jsNumber(number), neutralizeFormulas: false)
        case let .bool(flag)?: return flag ? "true" : "false"
        case let value?:
            // Arrays and objects don't appear in the columns; JS would print them unhelpfully too.
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return self.escape(String(decoding: data, as: UTF8.self), neutralizeFormulas: true)
        }
    }

    private static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\u{FF0B}", "\u{FF0D}", "\u{FF1D}", "\u{FF20}"]
    private static let leadingSpace: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]
    private static let quoted: Set<Unicode.Scalar> = ["\"", ",", "\r", "\n"]

    /// Scalars, not Characters: `"\r\n"` is one Character in Swift.
    private static func escape(_ text: String, neutralizeFormulas: Bool) -> String {
        var safe = text
        if neutralizeFormulas, let first = text.unicodeScalars.first(where: { !self.leadingSpace.contains($0) }),
           self.formulaStarts.contains(first)
        {
            safe = "'" + text
        }
        guard safe.unicodeScalars.contains(where: self.quoted.contains) else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `String(n)` in JavaScript: integers without a fraction, no exponent from 1e-6 up to 1e21.
    static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-Infinity" : "Infinity") }
        if value == 0 { return "0" }
        if value.rounded() == value, abs(value) < 1e21 {
            return String(format: "%.0f", value)
        }
        // Swift's description is the shortest round-trip form; expand its exponent like JS does.
        let description = "\(value)"
        guard let e = description.firstIndex(where: { $0 == "e" || $0 == "E" }),
              let exponent = Int(description[description.index(after: e)...]) else { return description }
        guard abs(value) >= 1e-6, abs(value) < 1e21 else {
            // JS keeps the exponent here, written `1e-7` / `1.5e+21` (Swift writes `1e-07`).
            return description[..<e] + "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        }
        var mantissa = String(description[..<e])
        let negative = mantissa.hasPrefix("-")
        if negative { mantissa.removeFirst() }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        var digits = whole + (parts.count > 1 ? String(parts[1]) : "")
        let point = whole.count + exponent
        while digits.count > 1, digits.hasSuffix("0"), point < digits.count { digits.removeLast() }
        let plain: String
        if point <= 0 {
            plain = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            plain = digits + String(repeating: "0", count: point - digits.count)
        } else {
            let index = digits.index(digits.startIndex, offsetBy: point)
            plain = String(digits[..<index]) + "." + String(digits[index...])
        }
        return (negative ? "-" : "") + plain
    }

    /// `new Date(ms).toISOString()`: UTC with milliseconds.
    static func isoTimestamp(_ value: JSONValue?) -> String? {
        guard let ms = value?.double, ms.isFinite, abs(ms) <= 8.64e15 else { return nil }
        // Whole milliseconds: a fractional Date would be truncated a millisecond early.
        let whole = Int64(ms.rounded(.down))
        let millis = ((whole % 1000) + 1000) % 1000
        let date = Date(timeIntervalSince1970: TimeInterval((whole - millis) / 1000))
        let seconds = date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
        return String(seconds.dropLast()) + String(format: ".%03lldZ", millis)
    }
}
