import Foundation

/// Deterministic usage for the built-in demo: 90 days of per-session activity with a weekday
/// pattern, quieter further back, answered in the shapes of `usage.status`, `usage.cost`, `sessions.usage`,
/// `sessions.usage.timeseries` and `sessions.usage.logs`.
enum DemoUsage {
    static let methods = UsageModel.methods

    private struct Model {
        let provider: String
        let model: String
        /// USD per million input, output, cache-read and cache-write tokens; nil when unpriced.
        let prices: (Double, Double, Double, Double)?
        /// Every `n`th day some requests come back without pricing.
        var unpricedEvery: Int?
    }

    private struct Session {
        let key: String
        let agentId: String
        let label: String?
        let channel: String
        let models: [(model: Model, share: Double)]
        let dailyTokens: Double
        let activeDays: Range<Int>
        /// What `sessions.usage.logs` returns, oldest first, matching the chat's transcript.
        let log: [(role: String, content: String)]
    }

    private static let opus = Model(provider: "anthropic", model: "claude-opus-4-8", prices: (15, 75, 1.5, 18.75))
    private static let sonnet = Model(provider: "anthropic", model: "claude-sonnet-5", prices: (3, 15, 0.3, 3.75))
    private static let sol = Model(provider: "openai", model: "gpt-5.6-sol", prices: (1.25, 10, 0.125, 0), unpricedEvery: 4)
    private static let flash = Model(provider: "google", model: "gemini-3.8-flash", prices: (0.3, 2.5, 0.03, 0))
    private static let local = Model(provider: "ollama", model: "qwen3-coder", prices: nil)

    private static let sessions: [Session] = [
        Session(key: "agent:main:main", agentId: "main", label: nil, channel: "webchat",
                models: [(opus, 1)], dailyTokens: 900_000, activeDays: 0..<90, log: mainLog),
        Session(key: "agent:main:discord:channel:123", agentId: "main", label: "home-lab", channel: "discord",
                models: [(sonnet, 1)], dailyTokens: 250_000, activeDays: 0..<90, log: homeLabLog),
        Session(key: "agent:main:dashboard:trip", agentId: "main", label: "Japan trip", channel: "webchat",
                models: [(sol, 1)], dailyTokens: 400_000, activeDays: 0..<18, log: tripLog),
        // Gemini's sign-in expired a few days ago (see usage.status), so this chat went quiet.
        Session(key: "agent:research:main", agentId: "research", label: nil, channel: "webchat",
                models: [(flash, 1)], dailyTokens: 150_000, activeDays: 3..<90, log: researchLog),
        Session(key: "agent:research:dashboard:papers", agentId: "research", label: "Paper digest", channel: "webchat",
                models: [(sonnet, 1)], dailyTokens: 600_000, activeDays: 1..<75, log: papersLog),
        Session(key: "agent:research:subagent:abc", agentId: "research", label: "Summarize arXiv 2401.x", channel: "webchat",
                models: [(local, 1)], dailyTokens: 300_000, activeDays: 2..<12, log: subagentLog),
        Session(key: "agent:coder:main", agentId: "coder", label: nil, channel: "webchat",
                models: [(sol, 0.6), (opus, 0.4)], dailyTokens: 1_200_000, activeDays: 0..<90, log: coderLog),
    ]

    /// The model a demo chat mainly runs on, so its row and replies match its usage.
    static func model(for key: String) -> (provider: String, model: String)? {
        guard let model = self.sessions.first(where: { $0.key == key })?.models.first?.model else { return nil }
        return (model.provider, model.model)
    }

    private struct Record {
        let session: Int
        let model: Model
        let dayOffset: Int
        let date: String
        let timestamp: Double
        let totals: UsageTotals
        let entries: Int
        let messages: UsageMessageCounts
    }

    // MARK: Dispatch

    static func handle(_ method: String, _ params: JSONValue, knownKeys: Set<String>, now: Date = Date()) throws -> JSONValue {
        switch method {
        case "usage.status": return self.status(now: now)
        case "usage.cost": return try self.cost(params, now: now)
        case "sessions.usage": return try self.sessionsUsage(params, knownKeys: knownKeys, now: now)
        case "sessions.usage.timeseries": return try self.timeseries(params, knownKeys: knownKeys, now: now)
        case "sessions.usage.logs": return try self.logs(params, knownKeys: knownKeys, now: now)
        default: throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
        }
    }

    private static func invalid(_ message: String) -> GatewayError {
        .rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }

    // MARK: Records

    private static func calendar(_ params: JSONValue) -> Calendar {
        UsageDates.calendar(params["timeZone"]?.string.flatMap(TimeZone.init(identifier:)) ?? .current)
    }

    private static func records(now: Date, calendar: Calendar) -> [Record] {
        let today = calendar.startOfDay(for: now)
        var records: [Record] = []
        for (index, session) in self.sessions.enumerated() {
            for offset in session.activeDays {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                let weekday = calendar.component(.weekday, from: day)
                let weekend = weekday == 1 || weekday == 7
                let wave = 1 + 0.35 * sin(Double(offset + index * 3) / 2.7)
                // Usage has grown: the last month is busiest, older months quieter.
                let growth = offset < 30 ? 1 : offset < 60 ? 0.6 : 0.35
                let base = session.dailyTokens * (weekend ? 0.3 : 1) * wave * growth
                let hour = Double(9 + (index * 2 + offset) % 9) * 3600
                var timestamp = day.timeIntervalSince1970 * 1000 + hour * 1000
                if offset == 0 { timestamp = min(timestamp, now.timeIntervalSince1970 * 1000 - Double(index + 1) * 420_000) }
                for (model, share) in session.models {
                    let tokens = Int(base * share)
                    guard tokens > 0 else { continue }
                    let entries = max(1, tokens / 40_000)
                    var totals = UsageTotals()
                    totals.input = tokens * 18 / 100
                    totals.output = tokens * 6 / 100
                    totals.cacheWrite = tokens * 6 / 100
                    totals.cacheRead = tokens - totals.input - totals.output - totals.cacheWrite
                    totals.totalTokens = tokens
                    let ref = "\(model.provider)/\(model.model)"
                    if let prices = model.prices {
                        var priced = 1.0
                        if let every = model.unpricedEvery, offset % every == 1 {
                            let missing = max(1, entries / 3)
                            totals.missingCostEntries = missing
                            totals.missingCostByModel = [ref: missing]
                            priced = 1 - Double(missing) / Double(entries + missing)
                        }
                        totals.inputCost = Double(totals.input) * prices.0 / 1e6 * priced
                        totals.outputCost = Double(totals.output) * prices.1 / 1e6 * priced
                        totals.cacheReadCost = Double(totals.cacheRead) * prices.2 / 1e6 * priced
                        totals.cacheWriteCost = Double(totals.cacheWrite) * prices.3 / 1e6 * priced
                        totals.totalCost = totals.inputCost + totals.outputCost + totals.cacheReadCost + totals.cacheWriteCost
                    } else {
                        totals.missingCostEntries = entries
                        totals.missingCostByModel = [ref: entries]
                    }
                    var messages = UsageMessageCounts()
                    messages.assistant = entries
                    messages.user = max(1, (entries + 2) / 3)
                    messages.toolCalls = entries / 2
                    messages.toolResults = entries / 2
                    messages.errors = offset % 7 == 3 ? 1 : 0
                    messages.total = messages.user + messages.assistant
                    records.append(Record(session: index, model: model, dayOffset: offset,
                                          date: UsageDates.key(day, calendar: calendar), timestamp: timestamp,
                                          totals: totals, entries: entries, messages: messages))
                }
            }
        }
        return records
    }

    /// The requested inclusive range as `YYYY-MM-DD` keys; 30 days by default.
    private static func range(_ params: JSONValue, now: Date, calendar: Calendar) throws -> (start: String, end: String) {
        let start = params["startDate"]?.text
        let end = params["endDate"]?.text
        if (start == nil) != (end == nil) { throw self.invalid("startDate and endDate must be provided together") }
        if let start, let end {
            guard UsageDates.date(fromKey: start, calendar: calendar) != nil, UsageDates.date(fromKey: end, calendar: calendar) != nil
            else { throw self.invalid("invalid startDate: expected a valid YYYY-MM-DD calendar date") }
            guard start <= end else { throw self.invalid("startDate must not be after endDate") }
            return (start, end)
        }
        let days = UsageDateRange.last(params["days"]?.int ?? 30, now: now, calendar: calendar)
        return (days.startKey, days.endKey)
    }

    // MARK: usage.status

    private static func status(now: Date) -> JSONValue {
        let ms = now.timeIntervalSince1970 * 1000
        // The budget matches what the demo spent on OpenAI over the last 30 days.
        let calendar = UsageDates.calendar()
        let month = UsageDateRange.last(30, now: now, calendar: calendar).startKey
        let openAISpend = self.records(now: now, calendar: calendar)
            .filter { $0.model.provider == "openai" && $0.date >= month }
            .reduce(0) { $0 + $1.totals.totalCost }
        return [
            "updatedAt": .number(ms.rounded()),
            "providers": [
                [
                    "provider": "anthropic", "displayName": "Claude", "plan": "Max", "accountEmail": "claw@example.com",
                    "windows": [
                        ["label": "5-hour", "usedPercent": 92, "resetAt": .number(ms + 38 * 60_000)],
                        ["label": "Weekly", "usedPercent": 61, "resetAt": .number(ms + 3 * 86_400_000 + 4 * 3_600_000)],
                        ["label": "Weekly", "groupLabel": "Opus", "usedPercent": 78, "resetAt": .number(ms + 3 * 86_400_000 + 4 * 3_600_000)],
                    ],
                ],
                [
                    "provider": "openai", "displayName": "OpenAI", "plan": "Pro",
                    "windows": [
                        ["label": "Daily requests", "usedPercent": 34, "resetAt": .number(ms + 7 * 3_600_000 + 12 * 60_000)],
                    ],
                    "billing": [
                        ["type": "balance", "label": "Credit balance", "amount": 42.5, "unit": "USD"],
                        ["type": "budget", "label": "Monthly budget", "used": .number((openAISpend * 100).rounded() / 100), "limit": 50,
                         "unit": "USD", "period": "month"],
                    ],
                ],
                ["provider": "google", "displayName": "Gemini", "windows": [],
                 "error": "Sign-in expired. Run `openclaw models auth google` to reconnect."],
                ["provider": "ollama", "displayName": "Ollama", "windows": [], "summary": "Local models aren't metered."],
            ],
        ]
    }

    // MARK: usage.cost

    private static func cost(_ params: JSONValue, now: Date) throws -> JSONValue {
        let calendar = self.calendar(params)
        let (start, end) = try self.range(params, now: now, calendar: calendar)
        if params["agentScope"]?.string == "all", params["agentId"]?.text != nil {
            throw self.invalid("agentScope=all cannot be combined with agentId")
        }
        let agent = params["agentScope"]?.string == "all" ? nil : params["agentId"]?.text ?? "main"
        let records = self.records(now: now, calendar: calendar).filter {
            $0.date >= start && $0.date <= end && (agent == nil || self.sessions[$0.session].agentId == agent)
        }
        let byDate = Dictionary(grouping: records, by: \.date)
        let daily = byDate.keys.sorted().map { date -> JSONValue in
            var day = self.json(byDate[date]!.reduce(.zero) { $0 + $1.totals })
            day["date"] = .string(date)
            return .object(day)
        }
        return [
            "updatedAt": .number((now.timeIntervalSince1970 * 1000).rounded()),
            "days": JSONValue(byDate.count),
            "daily": .array(daily),
            "totals": .object(self.json(records.reduce(.zero) { $0 + $1.totals })),
        ]
    }

    // MARK: sessions.usage

    private static func sessionsUsage(_ params: JSONValue, knownKeys: Set<String>, now: Date) throws -> JSONValue {
        let calendar = self.calendar(params)
        let (start, end) = try self.range(params, now: now, calendar: calendar)
        let key = params["key"]?.text
        let agentId = params["agentId"]?.text
        let allAgents = params["agentScope"]?.string == "all"
        if allAgents, key != nil || agentId != nil { throw self.invalid("agentScope=all cannot be combined with key or agentId") }
        if let key, !knownKeys.contains(key) { throw self.invalid("Invalid session key: \(key)") }
        let limit = max(1, min(1000, params["limit"]?.int ?? 50))
        let agent = allAgents ? nil : agentId ?? key.flatMap(SessionKey.agentId(from:)) ?? "main"
        let all = self.records(now: now, calendar: calendar).filter { $0.date >= start && $0.date <= end }
        let longRange = (UsageDates.date(fromKey: start, calendar: calendar).map { now.timeIntervalSince($0) } ?? 0) > 31 * 86400

        var indices = self.sessions.indices.filter { agent == nil || self.sessions[$0].agentId == agent }
        if let key { indices = indices.filter { self.sessions[$0].key == key } }
        let grouped = Dictionary(grouping: all.filter { indices.contains($0.session) }, by: \.session)
        // A long range is "still counting" one chat, so its row has no usage yet.
        let computing = key == nil && longRange ? "agent:main:discord:channel:123" : nil
        var matched = indices.filter { grouped[$0] != nil || key != nil }
        matched.sort { lhs, rhs in
            let l = grouped[lhs]?.reduce(UsageTotals.zero) { $0 + $1.totals } ?? .zero
            let r = grouped[rhs]?.reduce(UsageTotals.zero) { $0 + $1.totals } ?? .zero
            return l.totalCost == r.totalCost ? l.totalTokens > r.totalTokens : l.totalCost > r.totalCost
        }
        let counted = matched.filter { self.sessions[$0].key != computing }
        let records = counted.flatMap { grouped[$0] ?? [] }

        var rows: [JSONValue] = []
        for index in matched.prefix(limit) {
            let session = self.sessions[index]
            let mine = grouped[index] ?? []
            var row: [String: JSONValue] = [
                "key": .string(session.key), "sessionId": .string("demo-\(index)"), "scope": "instance",
                "agentId": .string(session.agentId), "channel": .string(session.channel),
                "modelProvider": .string(session.models[0].model.provider), "model": .string(session.models[0].model.model),
                "updatedAt": .number(mine.map(\.timestamp).max() ?? (now.timeIntervalSince1970 * 1000 - 86_400_000)),
            ]
            if let label = session.label { row["label"] = .string(label) }
            if session.key == computing {
                row["usage"] = .null
                row["computing"] = true
            } else {
                row["usage"] = self.summary(mine)
            }
            rows.append(.object(row))
        }

        let dates = Set(records.map(\.date)).sorted()
        let byDate = Dictionary(grouping: records, by: \.date)
        let costDaily = dates.map { date -> JSONValue in
            var day = self.json(byDate[date]!.reduce(.zero) { $0 + $1.totals })
            day["date"] = .string(date)
            return .object(day)
        }
        let daily = dates.map { date -> JSONValue in
            let day = byDate[date]!
            let totals = day.reduce(UsageTotals.zero) { $0 + $1.totals }
            return ["date": .string(date), "tokens": JSONValue(totals.totalTokens), "cost": .number(totals.totalCost),
                    "messages": JSONValue(day.reduce(0) { $0 + $1.messages.total }),
                    "toolCalls": JSONValue(day.reduce(0) { $0 + $1.messages.toolCalls }),
                    "errors": JSONValue(day.reduce(0) { $0 + $1.messages.errors })]
        }
        var messages = UsageMessageCounts()
        for record in records {
            messages.total += record.messages.total
            messages.user += record.messages.user
            messages.assistant += record.messages.assistant
            messages.toolCalls += record.messages.toolCalls
            messages.toolResults += record.messages.toolResults
            messages.errors += record.messages.errors
        }
        let byAgent = Dictionary(grouping: records) { self.sessions[$0.session].agentId }
        let byChannel = Dictionary(grouping: records) { self.sessions[$0.session].channel }
        var result: [String: JSONValue] = [
            "updatedAt": .number((now.timeIntervalSince1970 * 1000).rounded()),
            "startDate": .string(start),
            "endDate": .string(end),
            "sessions": .array(rows),
            "totals": .object(self.json(records.reduce(.zero) { $0 + $1.totals })),
            "aggregates": [
                "sessionCount": JSONValue(matched.count),
                "messages": self.json(messages),
                "tools": ["totalCalls": JSONValue(messages.toolCalls), "uniqueTools": 6, "tools": [
                    ["name": "exec", "count": JSONValue(messages.toolCalls / 2)],
                    ["name": "browser", "count": JSONValue(messages.toolCalls / 4)],
                ]],
                "byModel": .array(self.modelBuckets(records, provider: false)),
                "byProvider": .array(self.modelBuckets(records, provider: true)),
                "byAgent": .array(byAgent.keys.sorted().map { ["agentId": .string($0), "totals": .object(self.json(byAgent[$0]!.reduce(.zero) { $0 + $1.totals }))] }),
                "byChannel": .array(byChannel.keys.sorted().map { ["channel": .string($0), "totals": .object(self.json(byChannel[$0]!.reduce(.zero) { $0 + $1.totals }))] }),
                "daily": .array(daily),
                "costDaily": .array(costDaily),
            ],
        ]
        if computing != nil {
            result["cacheStatus"] = ["status": "partial", "cachedFiles": 6, "pendingFiles": 1, "staleFiles": 0]
        }
        return .object(result)
    }

    private static func modelBuckets(_ records: [Record], provider: Bool) -> [JSONValue] {
        let groups = Dictionary(grouping: records) { provider ? $0.model.provider : "\($0.model.provider)/\($0.model.model)" }
        return groups.values.map { group -> (UsageTotals, JSONValue) in
            let totals = group.reduce(UsageTotals.zero) { $0 + $1.totals }
            var bucket: [String: JSONValue] = ["provider": .string(group[0].model.provider),
                                               "count": JSONValue(group.reduce(0) { $0 + $1.entries }),
                                               "totals": .object(self.json(totals))]
            if !provider { bucket["model"] = .string(group[0].model.model) }
            return (totals, .object(bucket))
        }
        .sorted { $0.0.totalTokens > $1.0.totalTokens }
        .map(\.1)
    }

    private static func summary(_ records: [Record]) -> JSONValue {
        var summary = self.json(records.reduce(.zero) { $0 + $1.totals })
        let first = records.map(\.timestamp).min()
        let last = records.map(\.timestamp).max()
        if let first, let last {
            summary["firstActivity"] = .number(first)
            summary["lastActivity"] = .number(last)
            summary["durationMs"] = .number(Double(records.count) * 23 * 60_000)
        }
        summary["activityDates"] = JSONValue(Set(records.map(\.date)).sorted())
        var messages = UsageMessageCounts()
        for record in records {
            messages.total += record.messages.total
            messages.user += record.messages.user
            messages.assistant += record.messages.assistant
            messages.toolCalls += record.messages.toolCalls
            messages.toolResults += record.messages.toolResults
            messages.errors += record.messages.errors
        }
        summary["messageCounts"] = self.json(messages)
        summary["toolUsage"] = ["totalCalls": JSONValue(messages.toolCalls), "uniqueTools": 3, "tools": []]
        summary["modelUsage"] = .array(self.modelBuckets(records, provider: false))
        return .object(summary)
    }

    // MARK: Timeseries and logs

    private static func session(_ params: JSONValue, knownKeys: Set<String>, detail: String) throws -> (key: String, index: Int?) {
        guard let key = params["key"]?.text else { throw self.invalid("key is required for \(detail)") }
        guard knownKeys.contains(key) else { throw self.invalid("Invalid session key: \(key)") }
        return (key, self.sessions.firstIndex { $0.key == key })
    }

    private static func timeseries(_ params: JSONValue, knownKeys: Set<String>, now: Date) throws -> JSONValue {
        let (key, index) = try self.session(params, knownKeys: knownKeys, detail: "timeseries")
        let records = self.records(now: now, calendar: UsageDates.calendar()).filter { $0.session == index }
            .sorted { $0.timestamp < $1.timestamp }
        guard index != nil, !records.isEmpty else { throw self.invalid("No transcript found for session: \(key)") }
        // Two turns a day, the last 50.
        var points: [JSONValue] = []
        var cumulativeTokens = 0
        var cumulativeCost = 0.0
        for record in records {
            for half in 0..<2 {
                let tokens = half == 0 ? record.totals.totalTokens / 2 : record.totals.totalTokens - record.totals.totalTokens / 2
                let cost = record.totals.totalCost / 2
                cumulativeTokens += tokens
                cumulativeCost += cost
                points.append([
                    "timestamp": .number(record.timestamp + Double(half) * 2_700_000 - (record.dayOffset == 0 ? 2_700_000 : 0)),
                    "input": JSONValue(record.totals.input / 2), "output": JSONValue(record.totals.output / 2),
                    "cacheRead": JSONValue(record.totals.cacheRead / 2), "cacheWrite": JSONValue(record.totals.cacheWrite / 2),
                    "totalTokens": JSONValue(tokens), "cost": .number(cost),
                    "cumulativeTokens": JSONValue(cumulativeTokens), "cumulativeCost": .number(cumulativeCost),
                ])
            }
        }
        return ["sessionId": .string("demo-\(index!)"), "points": .array(Array(points.suffix(50)))]
    }

    private static func logs(_ params: JSONValue, knownKeys: Set<String>, now: Date) throws -> JSONValue {
        let (_, index) = try self.session(params, knownKeys: knownKeys, detail: "logs")
        let limit = max(1, min(1000, params["limit"]?.int ?? 200))
        guard let index else { return ["logs": []] }
        let records = self.records(now: now, calendar: UsageDates.calendar()).filter { $0.session == index }
        let last = records.map(\.timestamp).max() ?? now.timeIntervalSince1970 * 1000
        let perToken = records.isEmpty ? 0 : records.reduce(0) { $0 + $1.totals.totalCost } / Double(max(1, records.reduce(0) { $0 + $1.totals.totalTokens }))
        let unpriced = self.sessions[index].models.allSatisfy { $0.model.prices == nil }
        let script = self.sessions[index].log
        var logs: [JSONValue] = []
        for (step, line) in script.enumerated() {
            var entry: [String: JSONValue] = [
                "timestamp": .number(last - Double(script.count - 1 - step) * 95_000),
                "role": .string(line.role),
                "content": .string(line.content),
            ]
            if line.role == "assistant" {
                let tokens = 8_000 + (step * 3_137) % 21_000
                entry["tokens"] = JSONValue(tokens)
                if !unpriced { entry["cost"] = .number(Double(tokens) * perToken) }
            }
            logs.append(.object(entry))
        }
        return ["logs": .array(Array(logs.suffix(limit)))]
    }

    // MARK: JSON

    private static func json(_ totals: UsageTotals) -> [String: JSONValue] {
        var json: [String: JSONValue] = [
            "input": JSONValue(totals.input), "output": JSONValue(totals.output),
            "cacheRead": JSONValue(totals.cacheRead), "cacheWrite": JSONValue(totals.cacheWrite),
            "totalTokens": JSONValue(totals.totalTokens), "totalCost": .number(totals.totalCost),
            "inputCost": .number(totals.inputCost), "outputCost": .number(totals.outputCost),
            "cacheReadCost": .number(totals.cacheReadCost), "cacheWriteCost": .number(totals.cacheWriteCost),
            "missingCostEntries": JSONValue(totals.missingCostEntries),
        ]
        if !totals.missingCostByModel.isEmpty { json["missingCostByModel"] = .object(totals.missingCostByModel.mapValues { JSONValue($0) }) }
        return json
    }

    private static func json(_ messages: UsageMessageCounts) -> JSONValue {
        ["total": JSONValue(messages.total), "user": JSONValue(messages.user), "assistant": JSONValue(messages.assistant),
         "toolCalls": JSONValue(messages.toolCalls), "toolResults": JSONValue(messages.toolResults),
         "errors": JSONValue(messages.errors)]
    }

    // MARK: Log scripts

    private static let mainLog: [(role: String, content: String)] = [
        ("user", "Can you check disk usage and show me a quick status?"),
        ("assistant", "Checking the volumes now."),
        ("tool", "exec: df -h"),
        ("toolResult", "Filesystem      Size  Used Avail Use% Mounted on\n/dev/disk3s1   926G  411G  490G  46% /\n/dev/disk3s6   926G  7.0G  490G   2% /System/Volumes/VM"),
        ("assistant", "The root volume is 46% full, so there's plenty of room. The VM volume is barely used. Here's a quick chart."),
        ("tool", "exec: bash disk-report.sh --chart"),
        ("toolResult", "Wrote disk-chart.png (640x400)"),
        ("assistant", "I attached the chart and the script that made it, disk-report.sh, in case you want to rerun it."),
        ("user", "Can you sketch that as a little gauge?"),
        ("assistant", "Here's the root volume as a gauge: 46% used, drawn as an SVG arc."),
        ("user", "Nice. Which folders are the biggest?"),
        ("tool", "exec: du -sh ~/* | sort -h | tail -n 4"),
        ("toolResult", "18G\t/Users/claw/Movies\n24G\t/Users/claw/projects\n31G\t/Users/claw/Library\n96G\t/Users/claw/VMs"),
        ("assistant", "The VMs folder is the largest at 96 GB, then Library at 31 GB and projects at 24 GB."),
        ("user", "Anything safe to clean up?"),
        ("tool", "exec: du -sh ~/Library/Caches"),
        ("toolResult", "7.4G\t/Users/claw/Library/Caches"),
        ("assistant", "Caches take 7.4 GB and are safe to clear, but nothing is urgent at 46%."),
        ("user", "Leave them for now. Remind me if it passes 80%."),
        ("assistant", "Will do. disk-report.sh already flags any volume over 80%, so I'll run it every morning and tell you if one crosses."),
    ]

    private static let homeLabLog: [(role: String, content: String)] = [
        ("user", "The lab temperature sensor looks noisy tonight."),
        ("tool", "exec: curl -s http://lab-pi.local:9100/metrics | grep temp_celsius"),
        ("toolResult", "lab_temp_celsius{sensor=\"rack\"} 27.9\nlab_temp_celsius{sensor=\"rack\"} 31.4\nlab_temp_celsius{sensor=\"rack\"} 26.8"),
        ("assistant", "Readings jump about 4 °C between samples, which looks like a loose sensor rather than real heat."),
        ("user", "Can you smooth it for the dashboard?"),
        ("tool", "exec: sed -i 's/window: 1m/window: 5m/' ~/lab/grafana/temp.yaml"),
        ("toolResult", "Updated temp.yaml"),
        ("assistant", "The dashboard now averages over 5 minutes. I'll keep an eye on the home-lab channel and flag anything unusual."),
        ("user", "Is the Discord bridge still up?"),
        ("assistant", "Yes, the Discord bridge is online and relaying this channel."),
    ]

    private static let tripLog: [(role: String, content: String)] = [
        ("user", "Plan a gentle first day in Tokyo."),
        ("assistant", "Start with Meiji Shrine, a low-key lunch, and an early evening in Shinjuku."),
        ("user", "And a day in Kyoto?"),
        ("tool", "browser: search \"Fushimi Inari early morning crowds\""),
        ("toolResult", "Fushimi Inari is quietest before 8 AM; the upper trails stay calm most of the day."),
        ("assistant", "Kyoto day plan: Fushimi Inari at 7 AM, breakfast nearby, Gion in the afternoon, and ramen in Pontocho."),
        ("user", "Email the Kyoto plan to the family."),
        ("tool", "mail.send_email: To travel@example.com, family@example.com, Subject: Kyoto day plan"),
        ("toolResult", "Sent to 2 recipients."),
        ("assistant", "Sent the Kyoto day plan to travel@example.com and family@example.com."),
    ]

    private static let researchLog: [(role: String, content: String)] = [
        ("user", "What's in the research queue?"),
        ("tool", "notes.read_notes: Research/Queue"),
        ("toolResult", "1. Diffusion papers this week\n2. Compare vector databases\n3. OpenClaw plugin API changes"),
        ("assistant", "Three items: this week's diffusion papers, a vector database comparison, and the OpenClaw plugin API changes."),
        ("user", "Start the diffusion digest in its own chat."),
        ("assistant", "Started Paper digest for the diffusion papers. I'll post the summary there."),
        ("user", "Install feedparser so you can watch arXiv feeds."),
        ("tool", "exec: pip install --user feedparser"),
        ("toolResult", "Approval denied: no route to an approver."),
        ("assistant", "The install wasn't approved, so I'll read the feeds with curl instead. Research queue is clear."),
    ]

    private static let papersLog: [(role: String, content: String)] = [
        ("user", "Summarize the latest diffusion papers."),
        ("tool", "exec: curl -sSL https://arxiv.org/list/cs.AI/new | head -n 200"),
        ("toolResult", "Approval expired before anyone answered."),
        ("tool", "browser: open https://arxiv.org/list/cs.CV/new"),
        ("toolResult", "42 new submissions, 7 mention diffusion."),
        ("assistant", "Found 7 new diffusion papers. Reading the three most cited first."),
        ("tool", "subagent: Summarize arXiv 2401.x"),
        ("toolResult", "The paper mainly improves how retrieval-augmented summaries are evaluated."),
        ("assistant", "The main themes are consistency models, faster sampling, and video generation. Three papers summarized."),
        ("user", "Which one should I read first?"),
        ("assistant", "Start with the consistency-model paper: it's short and the others build on it."),
    ]

    private static let subagentLog: [(role: String, content: String)] = [
        ("user", "Summarize arXiv 2401.x in three sentences."),
        ("tool", "browser: open https://arxiv.org/abs/2401.x"),
        ("toolResult", "Title: Evaluating Retrieval-Augmented Summaries. 14 pages, 6 figures."),
        ("assistant", "Reading the abstract and the evaluation section."),
        ("tool", "browser: extract section 4"),
        ("toolResult", "We propose a faithfulness metric that checks each summary sentence against the retrieved passages."),
        ("assistant", "The paper mainly improves how retrieval-augmented summaries are evaluated, with a sentence-level faithfulness metric."),
    ]

    private static let coderLog: [(role: String, content: String)] = [
        ("user", "Update the Homebrew packages."),
        ("tool", "exec: brew upgrade --quiet"),
        ("toolResult", "Upgraded 6 packages: node, swiftlint, gh, ripgrep, jq, xcodegen"),
        ("assistant", "Upgraded 6 packages. Nothing needed a restart."),
        ("user", "Clear the caches too."),
        ("tool", "exec: rm -rf ~/Library/Caches"),
        ("toolResult", "Approval denied: Deletes files outside the workspace."),
        ("assistant", "That was denied, so I left the caches alone."),
        ("user", "Build the app and run the tests."),
        ("tool", "exec: swift build && swift test --parallel"),
        ("toolResult", "Build complete! Test run with 214 tests passed after 38.2 seconds."),
        ("assistant", "The build is clean and all 214 tests pass."),
        ("user", "Push it."),
        ("tool", "exec: git push --force origin main"),
        ("toolResult", "Cancelled: the run was aborted."),
        ("assistant", "The force-push was cancelled. No active coding run."),
    ]
}
