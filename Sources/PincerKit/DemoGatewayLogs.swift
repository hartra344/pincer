import Foundation

/// The demo Gateway's log file: seeded history across every level and subsystem, a few new lines
/// on every `logs.tail`, and lines for chat and approval activity. `tail` follows the Gateway's
/// byte-offset cursor rules (`src/logging/log-tail.ts`), like `mock-gateway/logs.mjs`.
struct DemoGatewayLogs {
    private(set) var file: String
    private(set) var lines: [String] = []
    /// Byte offset where each line starts; every line ends with "\n".
    private var starts: [Int] = []
    private(set) var size = 0
    private var lastTick: Date
    private var counter = 0

    static let paramKeys: Set<String> = ["cursor", "limit", "maxBytes"]
    static let defaultLimit = 500
    static let defaultMaxBytes = 250_000

    init(now: Date = Date()) {
        self.file = Self.path(for: now)
        self.lastTick = now
        self.seed(now: now)
    }

    static func path(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "/tmp/openclaw/openclaw-\(formatter.string(from: date)).log"
    }

    // MARK: Writing

    mutating func appendRaw(_ line: String) {
        self.starts.append(self.size)
        self.lines.append(line)
        self.size += line.utf8.count + 1
    }

    /// Appends a tslog-shaped JSON line, like the Gateway's file logger.
    mutating func log(_ level: GatewayLogLevel, _ subsystem: String, _ message: String, at date: Date = Date(),
                      meta: [String: Any]? = nil)
    {
        self.appendRaw(Self.line(level, subsystem, message, at: date, meta: meta))
    }

    static func line(_ level: GatewayLogLevel, _ subsystem: String, _ message: String, at date: Date,
                     meta: [String: Any]? = nil, repeatName: Bool = false) -> String
    {
        let name = #"{"subsystem":"\#(subsystem)"}"#
        let time = Self.iso(date)
        let ids: [GatewayLogLevel: Int] = [.trace: 1, .debug: 2, .info: 3, .warn: 4, .error: 5, .fatal: 6]
        var object: [String: Any] = [
            "_meta": [
                "runtime": "node", "runtimeVersion": "24.3.0", "hostname": "unknown", "name": name,
                "parentNames": ["openclaw"], "date": time, "logLevelId": ids[level] ?? 3,
                "logLevelName": level.label,
            ] as [String: Any],
            "time": time,
        ]
        var args: [Any] = repeatName ? [name] : []
        if let meta { args.append(meta) }
        args.append(message)
        for (index, arg) in args.enumerated() { object[String(index)] = arg }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Time passing on the demo host: 1–4 plausible lines since the last read.
    mutating func tick(now: Date = Date()) {
        let elapsed = now.timeIntervalSince(self.lastTick)
        guard elapsed >= 0.5 else { return }
        let count = Int.random(in: 1...4)
        for step in 1...count {
            let at = self.lastTick.addingTimeInterval(elapsed * Double(step) / Double(count))
            let (level, subsystem, message) = Self.ambient(self.counter)
            self.counter += 1
            self.log(level, subsystem, message, at: at)
        }
        self.lastTick = now
    }

    // MARK: logs.tail

    mutating func tail(_ params: JSONValue, now: Date = Date()) throws -> JSONValue {
        let (cursor, limit, maxBytes) = try Self.validate(params)
        self.tick(now: now)
        let slice = self.slice(cursor: cursor, limit: limit, maxBytes: maxBytes)
        var result: [String: JSONValue] = [
            "file": .string(self.file), "cursor": JSONValue(slice.cursor), "size": JSONValue(self.size),
            "lines": JSONValue(slice.lines), "truncated": .bool(slice.truncated), "reset": .bool(slice.reset),
        ]
        if let skipped = slice.skippedBytes { result["skippedBytes"] = JSONValue(skipped) }
        return .object(result)
    }

    /// The Gateway's closed params: `cursor` ≥ 0, `limit` 1…5000, `maxBytes` 1…1,000,000.
    static func validate(_ params: JSONValue) throws -> (cursor: Int?, limit: Int, maxBytes: Int) {
        func invalid(_ message: String) -> GatewayError {
            GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid logs.tail params: \(message)", details: nil)
        }
        func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let value = params[key] else { return nil }
            guard case let .number(number) = value, number.rounded() == number, let int = Int(exactly: number),
                  range.contains(int)
            else { throw invalid("\(key) must be an integer in \(range.lowerBound)…\(range.upperBound)") }
            return int
        }
        guard let object = params.object else { throw invalid("expected an object") }
        if let unknown = object.keys.sorted().first(where: { !Self.paramKeys.contains($0) }) {
            throw invalid("unexpected property \(unknown)")
        }
        return (try integer("cursor", in: 0...Int.max), try integer("limit", in: 1...5_000) ?? Self.defaultLimit,
                try integer("maxBytes", in: 1...1_000_000) ?? Self.defaultMaxBytes)
    }

    struct Slice: Equatable {
        var cursor: Int
        var lines: [String]
        var truncated = false
        var reset = false
        var skippedBytes: Int?
    }

    func slice(cursor: Int?, limit: Int, maxBytes: Int) -> Slice {
        var start: Int
        var truncated = false
        var reset = false
        var skipped: Int?
        if let cursor {
            if cursor > self.size {
                reset = true
                start = max(0, self.size - maxBytes)
                truncated = start > 0
            } else {
                start = cursor
                if self.size - start > maxBytes {
                    reset = true
                    truncated = true
                    let bounded = max(0, self.size - maxBytes)
                    skipped = bounded - start
                    start = bounded
                }
            }
        } else {
            start = max(0, self.size - maxBytes)
            truncated = start > 0
        }
        guard self.size > start else {
            return Slice(cursor: self.size, lines: [], truncated: truncated, reset: reset, skippedBytes: skipped)
        }
        // A start mid-line drops that partial line, like reading the file from a byte offset.
        var lines = Array(self.lines[self.lowerBound(start)...])
        if lines.count > limit {
            truncated = true
            lines = Array(lines.suffix(limit))
        }
        return Slice(cursor: self.size, lines: lines, truncated: truncated, reset: reset, skippedBytes: skipped)
    }

    /// Index of the first line starting at or after `offset`.
    private func lowerBound(_ offset: Int) -> Int {
        var low = 0
        var high = self.starts.count
        while low < high {
            let mid = (low + high) / 2
            if self.starts[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Activity

    mutating func chatStarted(runId: String, sessionKey: String, model: String, text: String) {
        self.log(.info, "gateway", "chat.send \(sessionKey) → \(runId)")
        self.log(.debug, "agent", "\(runId): model \(model), prompt \(text.count) chars")
    }

    mutating func chatFinished(runId: String, outputTokens: Int, usedTool: Bool) {
        if usedTool { self.log(.debug, "agent", "\(runId): tool exec finished in 812ms") }
        self.log(.info, "agent", "\(runId): run finished (\(outputTokens.formatted()) output tokens)")
    }

    mutating func approvalRequested(id: String, command: String) {
        self.log(.warn, "exec", "approval \(id) waiting for a reviewer: \(command)")
    }

    mutating func approvalResolved(id: String, decision: String) {
        self.log(.info, "exec", "approval \(id) resolved: \(decision)")
    }

    // MARK: Content

    private static let ambientLines: [(GatewayLogLevel, String, String)] = [
        (.debug, "gateway", "tick → %d operator clients"),
        (.info, "channels/discord", "message in #general from sam (%d chars)"),
        (.trace, "gateway", "sessions.list served in %dms"),
        (.debug, "channels/discord", "heartbeat ack in %dms"),
        (.info, "agent", "run_bg%d: heartbeat check finished, nothing to report"),
        (.debug, "cron", "morning-briefing: next run in %d minutes"),
        (.info, "plugins", "weather: refreshed forecast for Seattle (%d locations)"),
        (.trace, "agent", "tool read: memory/notes.md (%d bytes)"),
        (.warn, "channels/telegram", "rate limited by Telegram, retrying in %ds"),
        (.debug, "gateway", "config hot-reload: no changes (%d files watched)"),
        (.info, "channels/discord", "reaction added in #finances (%d total)"),
        (.debug, "plugins", "browser: page pool %d/4 in use"),
        (.info, "gateway", "ws client connected (conn_%d, operator)"),
        (.trace, "channels/discord", "gateway event MESSAGE_UPDATE (%d bytes)"),
        (.warn, "plugins", "browser: page load took %d.4s (slow)"),
        (.debug, "agent", "context for agent:main:main at %d%% of the window"),
        (.info, "cron", "disk-check queued (%d in queue)"),
        (.error, "channels/discord", "attachment upload failed (HTTP 5%02d), will retry"),
        (.debug, "gateway", "push.web: sent %d notifications"),
        (.info, "agent", "run_bg%d: summarized 3 unread threads"),
    ]

    private static func ambient(_ index: Int) -> (GatewayLogLevel, String, String) {
        let template = Self.ambientLines[index % Self.ambientLines.count]
        let number = 2 + (index * 37 + 11) % 97
        return (template.0, template.1, String(format: template.2, number))
    }

    private mutating func seed(now: Date) {
        let start = now.addingTimeInterval(-90 * 60)
        var offset: TimeInterval = 0
        func at(_ step: TimeInterval) -> Date {
            offset += step
            return start.addingTimeInterval(offset)
        }
        let boot: [(GatewayLogLevel, String, String)] = [
            (.info, "gateway", "OpenClaw 2026.9.2 starting (pid 4121, node 24.3.0)"),
            (.debug, "gateway", "config loaded from ~/.openclaw/openclaw.json (revision 42)"),
            (.info, "gateway", "listening on ws://127.0.0.1:18789"),
            (.info, "gateway", "tailscale serve: https://claw.tailnet-example.ts.net → 127.0.0.1:18789"),
            (.debug, "plugins", "loading 5 plugins"),
            (.info, "plugins", "weather 1.4.0 enabled"),
            (.info, "plugins", "browser 0.9.1 enabled (headless)"),
            (.info, "channels/discord", "connected as Claw#0042 (2 servers)"),
            (.info, "channels/telegram", "polling started for @claw_home_bot"),
            (.info, "cron", "scheduler started: 3 jobs (1 paused)"),
            (.debug, "agent", "agents ready: main, research, coder"),
        ]
        for (level, subsystem, message) in boot { self.log(level, subsystem, message, at: at(0.4)) }
        // Older Gateway builds repeat the logger name as the first argument.
        self.appendRaw(Self.line(.info, "gateway", "control UI served at /", at: at(0.3), repeatName: true))
        // Plain text written straight to the file, with and without ANSI colors.
        self.appendRaw("(node:4121) [DEP0040] DeprecationWarning: The `punycode` module is deprecated.")
        self.appendRaw("\u{1B}[33mwarn\u{1B}[39m \u{1B}[2m[doctor]\u{1B}[22m Tailscale Serve certificate renews in 9 days")
        self.log(.info, "gateway", "ws client connected (conn_1, operator)", at: at(4),
                 meta: ["client": "openclaw-control-ui", "scopes": ["operator.read", "operator.write"]])

        var index = 0
        for minute in stride(from: 1.0, to: 88.0, by: 0.65) {
            let date = start.addingTimeInterval(minute * 60)
            switch index {
            case 20:
                self.log(.warn, "channels/discord", "gateway session invalidated, resuming (seq 18231)", at: date)
            case 34:
                self.log(.error, "cron", "disk-check failed: exit code 1 (df: /Volumes/Backup: No such file or directory)",
                         at: date)
            case 52:
                self.log(.fatal, "plugins", "browser: worker crashed (SIGSEGV); restarting worker", at: date)
                self.log(.info, "plugins", "browser: worker restarted (pid 5530)", at: date.addingTimeInterval(1.2))
            case 70:
                self.log(.debug, "agent", "prompt assembled for agent:research:dashboard:papers: " + Self.longPrompt, at: date)
            case 88:
                self.log(.info, "exec", "approval approval_demo_1 resolved: allow-once", at: date)
            case 101:
                self.log(.error, "channels/telegram", "getUpdates failed: ETIMEDOUT, retrying in 5s", at: date)
            default:
                let (level, subsystem, message) = Self.ambient(self.counter)
                self.counter += 1
                self.log(level, subsystem, message, at: date)
            }
            index += 1
        }
        self.lastTick = now
    }

    private static let longPrompt: String = {
        let paragraph = "You are Scout, a research agent. Summarize new papers on retrieval-augmented generation, "
            + "note methods, datasets and results, flag anything that contradicts earlier summaries, and link sources. "
        return String(repeating: paragraph, count: 18) + "(end of prompt)"
    }()
}
