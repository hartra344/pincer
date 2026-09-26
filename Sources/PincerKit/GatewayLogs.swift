import Foundation

// MARK: Lines

/// A log level from the Gateway's file log (tslog's `logLevelName`, lowercased).
public enum GatewayLogLevel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case trace, debug, info, warn, error, fatal

    public var id: String { self.rawValue }
    /// Badge text: never color alone.
    public var label: String { self.rawValue.uppercased() }
}

/// The level toggles, stored as a bitmask (`@AppStorage("gatewayLogs.levels")`).
public struct GatewayLogLevels: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public init(_ level: GatewayLogLevel) {
        self.init(rawValue: 1 << (GatewayLogLevel.allCases.firstIndex(of: level) ?? 0))
    }

    public static let all = GatewayLogLevels(GatewayLogLevel.allCases.map(GatewayLogLevels.init))
    /// Trace and debug are off until asked for.
    public static let defaults: GatewayLogLevels = [.init(.info), .init(.warn), .init(.error), .init(.fatal)]

    public func contains(_ level: GatewayLogLevel) -> Bool { self.contains(GatewayLogLevels(level)) }

    public mutating func toggle(_ level: GatewayLogLevel) {
        let bit = GatewayLogLevels(level)
        if self.contains(bit) { self.remove(bit) } else { self.insert(bit) }
    }
}

/// One raw line from `logs.tail`, parsed like the Gateway's own `parseLogLine`
/// (`src/logging/parse-log-line.ts`) and the Control UI's log page.
public struct GatewayLogLine: Hashable, Sendable {
    public let raw: String
    public let level: GatewayLogLevel?
    /// The line's time as written (`time`, else `_meta.date`).
    public let timeText: String?
    public let time: Date?
    public let subsystem: String?
    /// Control sequences stripped; the full text, for copy and export.
    public let message: String

    public init(raw: String, level: GatewayLogLevel?, timeText: String?, subsystem: String?, message: String) {
        self.raw = raw
        self.level = level
        self.timeText = timeText
        self.time = timeText.flatMap(Self.date)
        self.subsystem = subsystem
        self.message = message
    }

    public static func parse(_ raw: String) -> GatewayLogLine {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
        else {
            return GatewayLogLine(raw: raw, level: nil, timeText: nil, subsystem: nil, message: GatewayLogs.stripControls(raw))
        }
        let meta = object["_meta"] as? [String: Any]
        let context = Self.context(object, meta: meta)
        let levelRaw = (meta?["logLevelName"] as? String) ?? (object["level"] as? String)
        let time = (object["time"] as? String) ?? (meta?["date"] as? String)
        let subsystem = context.subsystem ?? (object["subsystem"] as? String) ?? context.module
        let message = (object["message"] as? String) ?? Self.positionalMessage(object, meta: meta)
        return GatewayLogLine(
            raw: raw,
            level: levelRaw.flatMap { GatewayLogLevel(rawValue: $0.lowercased()) },
            timeText: time,
            subsystem: subsystem.map(GatewayLogs.stripControls).flatMap { $0.isEmpty ? nil : $0 },
            message: GatewayLogs.stripControls(message))
    }

    private struct Context {
        var subsystem: String?
        var module: String?
        var plugin: String?
    }

    /// `_meta.name` (tslog's logger name) holds `{"subsystem":…}` as JSON; older lines repeat it as arg "0".
    private static func context(_ object: [String: Any], meta: [String: Any]?) -> Context {
        let fromMeta = Self.parseName(meta?["name"])
        if let name = meta?["name"] as? String, let first = object["0"] as? String, name == first { return fromMeta }
        let positional = Self.parseName(object["0"])
        return Context(subsystem: fromMeta.subsystem ?? positional.subsystem, module: fromMeta.module ?? positional.module,
                       plugin: fromMeta.plugin ?? positional.plugin)
    }

    private static func parseName(_ value: Any?) -> Context {
        guard let text = value as? String, text.drop(while: \.isWhitespace).hasPrefix("{"),
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Context() }
        return Context(subsystem: object["subsystem"] as? String, module: object["module"] as? String,
                       plugin: object["plugin"] as? String)
    }

    /// tslog's positional args "0", "1", … joined with spaces (non-strings as JSON). Arg "0" is
    /// left out when it only repeats the logger name, so the message doesn't start with `{"subsystem":…}`.
    private static func positionalMessage(_ object: [String: Any], meta: [String: Any]?) -> String {
        let name = meta?["name"] as? String
        let keys = object.keys.compactMap { key -> (Int, String)? in
            guard !key.isEmpty, key.allSatisfy(\.isASCIIDigit), let index = Int(key) else { return nil }
            return (index, key)
        }
        .sorted { $0.0 < $1.0 }
        var parts: [String] = []
        for (index, key) in keys {
            let value = object[key]
            if let text = value as? String {
                if index == 0, let name, text == name, text.drop(while: \.isWhitespace).hasPrefix("{"), keys.count > 1 {
                    continue
                }
                parts.append(text)
            } else if let value, !(value is NSNull) {
                parts.append(Self.json(value))
            }
        }
        return parts.joined(separator: " ")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    static func date(_ text: String) -> Date? {
        Self.isoFractional.date(from: text) ?? Self.isoPlain.date(from: text)
    }
}

private extension Character {
    var isASCIIDigit: Bool { self.isASCII && self.isNumber }
}

/// A row in the log viewer: a parsed line, or a marker Pincer inserts (rotation, skipped output).
public struct GatewayLogEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case line
        /// Centered note between lines; never filtered, copied or exported.
        case marker(String)
    }

    /// Increases with arrival order; stable while the entry is buffered.
    public let id: Int
    public let kind: Kind
    public let line: GatewayLogLine
    /// The message capped for display; copy and export use `line.message`.
    public let displayMessage: String
    /// `raw` capped for "Show Raw".
    public let displayRaw: String
    /// Lowercased, diacritic-folded message, subsystem and raw line, for search.
    let searchText: String
    let byteCount: Int

    public static let displayLimit = 2_000

    init(id: Int, line: GatewayLogLine) {
        self.id = id
        self.kind = .line
        self.line = line
        self.displayMessage = Self.capped(line.message)
        self.displayRaw = Self.capped(line.raw)
        self.searchText = GatewayLogs.normalize([line.message, line.subsystem ?? "", line.raw].joined(separator: "\n"))
        self.byteCount = line.raw.utf8.count
    }

    init(id: Int, marker: String) {
        self.id = id
        self.kind = .marker(marker)
        self.line = GatewayLogLine(raw: "", level: nil, timeText: nil, subsystem: nil, message: marker)
        self.displayMessage = marker
        self.displayRaw = marker
        self.searchText = ""
        self.byteCount = marker.utf8.count
    }

    public var isMarker: Bool { self.kind != .line }
    public var level: GatewayLogLevel? { self.line.level }
    public var subsystem: String? { self.line.subsystem }
    public var message: String { self.line.message }
    public var raw: String { self.line.raw }
    public var time: Date? { self.line.time }
    public var timeText: String? { self.line.timeText }

    /// "2026-09-26T18:00:00.000Z INFO [gateway] listening on …", the full message.
    public var copyText: String {
        [self.timeText, self.level?.label, self.subsystem.map { "[\($0)]" }, self.message]
            .compactMap(\.self)
            .joined(separator: " ")
    }

    static func capped(_ text: String) -> String {
        guard text.utf8.count > Self.displayLimit else { return text }
        let count = text.count
        guard count > Self.displayLimit else { return text }
        return String(text.prefix(Self.displayLimit)) + "… (+\((count - Self.displayLimit).formatted()) characters)"
    }
}

// MARK: Filtering, copy and export

public enum GatewayLogs {
    /// Case- and diacritic-insensitive form used for search.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Lines at an enabled level (unleveled lines always) matching the search, plus every marker.
    public static func filter(_ entries: [GatewayLogEntry], levels: GatewayLogLevels, query: String) -> [GatewayLogEntry] {
        let needle = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if levels == .all, needle.isEmpty { return entries }
        return entries.filter { entry in
            guard entry.kind == .line else { return true }
            if let level = entry.level, !levels.contains(level) { return false }
            return needle.isEmpty || entry.searchText.contains(needle)
        }
    }

    /// Lines (not markers) in `entries`.
    public static func lineCount(_ entries: [GatewayLogEntry]) -> Int {
        entries.reduce(0) { $0 + ($1.kind == .line ? 1 : 0) }
    }

    /// "time LEVEL [subsystem] message" per line; markers left out.
    public static func copyText(_ entries: [GatewayLogEntry]) -> String {
        entries.filter { $0.kind == .line }.map(\.copyText).joined(separator: "\n")
    }

    /// Raw lines as the Gateway sent them; markers left out. This is what Export writes.
    public static func rawText(_ entries: [GatewayLogEntry]) -> String {
        entries.filter { $0.kind == .line }.map(\.raw).joined(separator: "\n")
    }

    /// `openclaw-<gateway-name-slug>-<yyyyMMdd-HHmmss>.log`.
    public static func exportFilename(gatewayName: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let folded = gatewayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "openclaw-\(slug.isEmpty ? "gateway" : slug)-\(formatter.string(from: date)).log"
    }

    /// Removes ANSI CSI and OSC sequences and other C0 controls except tab.
    public static func stripControls(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x9B }) else {
            return text
        }
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B:
                index += 1
                guard index < scalars.count else { break }
                switch scalars[index].value {
                case 0x5B: // CSI: ESC [ params… intermediates… final (0x40–0x7E)
                    index += 1
                    while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
                    index += 1
                case 0x5D: // OSC: ESC ] … BEL or ESC \
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x07 { index += 1; break }
                        if scalars[index].value == 0x1B, index + 1 < scalars.count, scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                default: // nF/Fp/Fe escape: optional intermediates (0x20–0x2F), then a final byte, e.g. ESC ( B.
                    while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
                    index += 1
                }
            case 0x9B: // 8-bit CSI
                index += 1
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
                index += 1
            case 0x09:
                out.append(scalar)
                index += 1
            case 0..<0x20, 0x7F:
                index += 1
            default:
                out.append(scalar)
                index += 1
            }
        }
        return String(out)
    }
}

// MARK: Page

/// One `logs.tail` result: `{file, cursor, size, lines, truncated?, reset?, skippedBytes?}`.
public struct GatewayLogPage: Hashable, Sendable {
    public var file: String?
    /// Byte offset to send next time.
    public var cursor: Int
    public var size: Int
    public var lines: [String]
    /// Older lines were left out (limit or maxBytes).
    public var truncated: Bool
    /// The file rotated or shrank, or the cursor was fast-forwarded.
    public var reset: Bool
    /// Bytes skipped when a valid cursor fell more than maxBytes behind.
    public var skippedBytes: Int?

    public init(file: String?, cursor: Int, size: Int, lines: [String], truncated: Bool = false, reset: Bool = false,
                skippedBytes: Int? = nil)
    {
        self.file = file
        self.cursor = cursor
        self.size = size
        self.lines = lines
        self.truncated = truncated
        self.reset = reset
        self.skippedBytes = skippedBytes
    }

    public init?(_ json: JSONValue) {
        guard let cursor = json["cursor"]?.int, cursor >= 0 else { return nil }
        self.init(file: json["file"]?.text, cursor: cursor, size: json["size"]?.int ?? cursor,
                  lines: json["lines"]?.array?.compactMap(\.string) ?? [],
                  truncated: json["truncated"]?.bool ?? false, reset: json["reset"]?.bool ?? false,
                  skippedBytes: json["skippedBytes"]?.int)
    }
}

// MARK: Model

/// Gateway Logs for one Gateway: polls `logs.tail` while the page is showing and keeps the most
/// recent lines in memory only (2,000 entries or 8 MB). Nothing is written to disk or logged.
@MainActor
@Observable
public final class GatewayLogsModel {
    public enum Failure: Equatable, Sendable {
        /// The device lacks `operator.read`.
        case missingScope
        /// The Gateway couldn't read its log file (`UNAVAILABLE`); polling keeps retrying.
        case unavailable(String)
        case other(String)

        public var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }

        public var message: String {
            switch self {
            case .missingScope: GatewayLogsModel.missingScopeMessage
            case let .unavailable(message): "Couldn't read the gateway log: \(message). Retrying…"
            case let .other(message): message
            }
        }
    }

    /// Oldest first.
    public private(set) var entries: [GatewayLogEntry] = []
    /// The log file's path on the Gateway host.
    public private(set) var file: String?
    /// The byte offset sent with the next poll; nil before the first read.
    public private(set) var cursor: Int?
    public private(set) var size: Int?
    /// False when the Gateway has no `logs.tail`.
    public private(set) var supported = true
    public private(set) var hasLoaded = false
    public private(set) var isFetching = false
    public private(set) var failure: Failure?
    /// The first read came back truncated: older lines are on the Gateway host only.
    public private(set) var showsRecentOnly = false
    /// Buffered lines per level.
    public private(set) var levelCounts: [GatewayLogLevel: Int] = [:]
    public private(set) var lineCount = 0
    public private(set) var bufferedBytes = 0
    /// Bumped by `retry()`, so a view restarts polling.
    public private(set) var retryGeneration = 0
    /// Paused: no polling; the cursor is kept so Resume catches up.
    public var isPaused = false

    public var capacity = GatewayLogsModel.defaultCapacity
    public var byteCapacity = GatewayLogsModel.defaultByteCapacity
    /// Delay between polls; errors back off from here.
    public var interval: Duration = .seconds(2)

    public nonisolated static let defaultCapacity = 2_000
    public nonisolated static let defaultByteCapacity = 8 * 1024 * 1024
    public nonisolated static let limit = 500
    public nonisolated static let maxBytes = 250_000
    /// Responses with more lines than this are parsed off the main actor.
    nonisolated static let backgroundParseThreshold = 500

    public nonisolated static let missingScopeMessage =
        "Gateway Logs needs the operator.read scope. Approve it for this device on the Gateway host, then try again."

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private(set) var consecutiveFailures = 0

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?) {
        self.request = { method, params in try await connection.request(method, params, timeout: 10) }
        self.methods = { hello()?.methods }
    }

    /// For checks and previews: `methods` is the Gateway's advertised method list (nil or empty
    /// when unknown), `request` answers RPCs.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil }, request: @escaping Request) {
        self.request = request
        self.methods = methods
    }

    /// The wait before the next poll: the interval, doubling per consecutive failure up to 10 s.
    public var nextDelay: Duration { Self.delay(interval: self.interval, failures: self.consecutiveFailures) }

    public nonisolated static func delay(interval: Duration, failures: Int) -> Duration {
        guard failures > 1 else { return interval }
        let factor = 1 << min(failures - 1, 10)
        return min(interval * factor, max(interval, .seconds(10)))
    }

    /// Polls until cancelled, paused, unsupported or missing its scope.
    public func run() async {
        while !Task.isCancelled, !self.isPaused {
            await self.poll()
            guard self.supported, self.failure != .missingScope, !Task.isCancelled else { return }
            do { try await Task.sleep(for: self.nextDelay) } catch { return }
        }
    }

    /// One `logs.tail` request from the current cursor. Only one runs at a time.
    public func poll() async {
        guard !self.isFetching else { return }
        if let methods = self.methods(), !methods.isEmpty, !methods.contains("logs.tail") {
            self.markUnsupported()
            return
        }
        self.isFetching = true
        defer { self.isFetching = false }
        var params: [String: JSONValue] = ["limit": JSONValue(Self.limit), "maxBytes": JSONValue(Self.maxBytes)]
        if let cursor = self.cursor { params["cursor"] = JSONValue(cursor) }
        do {
            let result = try await self.request("logs.tail", .object(params))
            guard let page = GatewayLogPage(result) else {
                throw GatewayError.protocolViolation("logs.tail returned no cursor")
            }
            await self.apply(page)
            self.supported = true
            self.failure = nil
            self.consecutiveFailures = 0
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            self.markUnsupported()
        } catch {
            self.consecutiveFailures += 1
            switch error {
            case GatewayError.notConnected, GatewayError.closed: break
            default: self.failure = Self.failure(for: error)
            }
        }
        self.hasLoaded = true
    }

    /// Try Again: clears the error and restarts polling from the cursor.
    public func retry() {
        self.failure = nil
        self.consecutiveFailures = 0
        self.retryGeneration += 1
    }

    /// Empties the buffer; the cursor stays, so only newer lines arrive.
    public func clear() {
        self.entries = []
        self.levelCounts = [:]
        self.lineCount = 0
        self.bufferedBytes = 0
        self.showsRecentOnly = false
    }

    public func count(_ level: GatewayLogLevel) -> Int { self.levelCounts[level] ?? 0 }

    func apply(_ page: GatewayLogPage) async {
        let firstRead = self.cursor == nil
        var markers: [String] = []
        if let previous = self.file, let file = page.file, previous != file {
            markers.append("Now reading \(file)")
        } else if page.reset {
            if let skipped = page.skippedBytes, skipped > 0 {
                markers.append("Skipped \(Int64(skipped).formatted(.byteCount(style: .file))) of log output (Pincer fell behind)")
            } else {
                markers.append("Log file was rotated or truncated. Reading from the start.")
            }
        } else if page.truncated, !firstRead {
            markers.append("Some lines were skipped (too much output at once)")
        }
        if firstRead { self.showsRecentOnly = page.truncated }

        let raw = Array(page.lines.suffix(self.capacity))
        let parsed: [GatewayLogLine] = if raw.count > Self.backgroundParseThreshold {
            await Task.detached(priority: .userInitiated) { raw.map(GatewayLogLine.parse) }.value
        } else {
            raw.map(GatewayLogLine.parse)
        }

        var fresh = markers.map { marker in
            defer { self.nextId += 1 }
            return GatewayLogEntry(id: self.nextId, marker: marker)
        }
        fresh.reserveCapacity(fresh.count + parsed.count)
        for line in parsed {
            fresh.append(GatewayLogEntry(id: self.nextId, line: line))
            self.nextId += 1
        }
        self.cursor = page.cursor
        self.size = page.size
        if let file = page.file { self.file = file }
        self.append(fresh)
    }

    private func append(_ fresh: [GatewayLogEntry]) {
        guard !fresh.isEmpty else { return }
        var entries = self.entries
        var counts = self.levelCounts
        var lines = self.lineCount
        var bytes = self.bufferedBytes
        for entry in fresh {
            bytes += entry.byteCount
            guard entry.kind == .line else { continue }
            lines += 1
            if let level = entry.level { counts[level, default: 0] += 1 }
        }
        entries.append(contentsOf: fresh)
        var drop = 0
        while entries.count - drop > self.capacity || (bytes > self.byteCapacity && entries.count - drop > 1) {
            let evicted = entries[drop]
            bytes -= evicted.byteCount
            if evicted.kind == .line {
                lines -= 1
                if let level = evicted.level { counts[level, default: 1] -= 1 }
            }
            drop += 1
        }
        if drop > 0 { entries.removeFirst(drop) }
        self.entries = entries
        self.levelCounts = counts
        self.lineCount = lines
        self.bufferedBytes = bytes
    }

    private func markUnsupported() {
        self.supported = false
        self.failure = nil
        self.hasLoaded = true
    }

    static func failure(for error: Error) -> Failure {
        guard case let GatewayError.rpc(code, message, details) = error else { return .other(error.localizedDescription) }
        if code == "MISSING_SCOPE" || details?["code"]?.text == "MISSING_SCOPE" || message.lowercased().contains("operator.read") {
            return .missingScope
        }
        let prefix = "log read failed:"
        if message.lowercased().hasPrefix(prefix) {
            return .unavailable(message.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        if code == "UNAVAILABLE" { return .unavailable(message) }
        return .other(message)
    }
}
