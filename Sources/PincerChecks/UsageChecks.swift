import Foundation
import PincerKit

/// `UsageModel`, its types and formatting against scripted Gateways: decoding, params, states
/// and stale responses.
@MainActor
func checkUsage() async {
    let en = Locale(identifier: "en_US")

    // Decoding: tolerant of missing fields, `usage: null`, Double-typed counts and bad rows.
    let result = SessionsUsageResult(json(#"""
    {"updatedAt":1700000000000,"startDate":"2026-09-20","endDate":"2026-09-26",
     "sessions":[
       {"key":"agent:main:main","label":"Main","model":"claude-opus-4-8","modelProvider":"anthropic","updatedAt":1700000000000,
        "usage":{"input":10.0,"output":5,"cacheRead":100,"cacheWrite":1,"totalTokens":116,"totalCost":1.5,"missingCostEntries":0,
                 "firstActivity":1699990000000,"lastActivity":1700000000000,"durationMs":60000,
                 "messageCounts":{"total":4,"user":2,"assistant":2,"toolCalls":1,"toolResults":1,"errors":0},
                 "modelUsage":[{"provider":"anthropic","model":"claude-opus-4-8","count":2,"totals":{"totalTokens":116,"totalCost":1.5}}]}},
       {"key":"agent:coder:main","usage":null,"computing":true},
       {"label":"no key"},
       {"key":"agent:research:main","usage":{"totalTokens":40}}
     ],
     "totals":{"input":10,"output":5,"cacheRead":100,"cacheWrite":1,"totalTokens":156,"totalCost":1.5,"missingCostEntries":3,
               "missingCostByModel":{"ollama/qwen3":3}},
     "aggregates":{"sessionCount":12,"messages":{"total":4,"user":2,"assistant":2},
                   "byModel":[{"provider":"anthropic","model":"claude-opus-4-8","count":2,"totals":{"totalTokens":116,"totalCost":1.5}},
                              {"totals":{"totalTokens":40,"missingCostEntries":2}}],
                   "byAgent":[{"agentId":"main","totals":{"totalTokens":116}}],
                   "daily":[{"date":"2026-09-24","tokens":156,"cost":1.5}],
                   "unknownField":{"x":1}},
     "cacheStatus":{"status":"partial","pendingFiles":1}}
    """#))
    check(result?.sessions.map(\.key) == ["agent:main:main", "agent:coder:main", "agent:research:main"], "rows without key skipped, others kept")
    check(result?.sessions[0].usage?.totals.input == 10 && result?.sessions[0].usage?.totals.totalTokens == 116
          && result?.sessions[0].usage?.messageCounts?.total == 4 && result?.sessions[0].usage?.modelUsage.count == 1
          && result?.sessions[0].agentId == "main" && result?.sessions[0].provider == "anthropic", "session usage decoded, agent from key")
    check(result?.sessions[1].usage == nil && result?.sessions[1].computing == true, "usage: null row is computing")
    check(result?.sessions[2].usage?.totals.totalTokens == 40 && result?.sessions[2].usage?.totals.totalCost == 0
          && result?.sessions[2].usage?.firstActivity == nil, "missing optional fields default")
    check(result?.sessionCount == 12 && result?.aggregates.messages.total == 4 && result?.aggregates.byModel.count == 2
          && result?.aggregates.byModel[1].model == nil && result?.aggregates.byAgent.first?.key == "main", "aggregates decoded")
    check(result?.aggregates.daily.first?.hasCategories == false && result?.aggregates.costDaily == nil, "aggregates.daily has no categories")
    check(result?.totals.costStatus == .partial(missing: 3) && result?.totals.missingCostByModel == ["ollama/qwen3": 3], "partial cost status")
    check(result?.cacheStatus?.isIncomplete == true, "partial cacheStatus is incomplete")
    check(SessionsUsageResult(json(#"{}"#))?.sessions.isEmpty == true && SessionsUsageResult(json(#"[]"#)) == nil, "empty object ok, array rejected")

    let cost = CostUsageSummary(json(#"""
    {"updatedAt":1,"days":7,"daily":[{"date":"2026-09-24","input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10,"totalCost":0.5},
                                     {"date":"2026-09-25","totalTokens":5,"totalCost":0,"missingCostEntries":2},{"nodate":true}]}
    """#))
    check(cost?.daily.count == 2 && cost?.daily[0].hasCategories == true && cost?.totals.totalTokens == 15
          && cost?.totals.missingCostEntries == 2, "usage.cost without totals sums days")
    check(UsageTotals(json(#"{"input":1,"output":2,"cacheRead":3,"cacheWrite":4}"#)).totalTokens == 10, "missing totalTokens summed")

    let status = UsageStatusSummary(json(#"""
    {"updatedAt":1700000000000,"providers":[
      {"provider":"anthropic","displayName":"Claude","plan":"Max","windows":[{"label":"5h","usedPercent":82.4,"resetAt":1700003600000},{"groupLabel":"Opus","label":"Week","usedPercent":10}],
       "billing":[{"type":"budget","used":12,"limit":20,"unit":"USD"},{"type":"credits","amount":5,"unit":"credits"},{"amount":1}]},
      {"provider":"google","windows":[],"error":"expired"},
      {"windows":[]}
    ]}
    """#))
    check(status?.providers.count == 2 && status?.providers[0].windows.count == 2 && status?.providers[0].windows[1].title == "Opus · Week"
          && status?.providers[0].windows[0].resetAt == Date(timeIntervalSince1970: 1_700_003_600), "usage.status providers and windows")
    check(status?.providers[0].billing.count == 2 && status?.providers[0].billing[1].kind == .other("credits")
          && status?.providers[1].displayName == "Google" && status?.providers[1].error == "expired" && status?.refreshing == false,
          "billing decoded, provider name fallback")
    check(UsageTimeSeries(json("null"))?.points.isEmpty == true
          && UsageTimeSeries(json(#"{"points":[{"timestamp":2,"cumulativeTokens":5},{"timestamp":1,"cumulativeTokens":1},{"x":1}]}"#))?.points.map(\.cumulativeTokens) == [1, 5],
          "timeseries sorted, points without timestamp skipped")

    // Dates: Gregorian day keys in the device's zone, never shifted through UTC.
    check(UsageDates.utcOffset(secondsFromGMT: 19800) == "UTC+5:30" && UsageDates.utcOffset(secondsFromGMT: -28800) == "UTC-8"
          && UsageDates.utcOffset(secondsFromGMT: 0) == "UTC+0" && UsageDates.utcOffset(secondsFromGMT: -9000) == "UTC-2:30"
          && UsageDates.utcOffset(secondsFromGMT: 20700) == "UTC+5:45", "utcOffset like formatUtcOffset")
    let kolkata = UsageDates.calendar(TimeZone(identifier: "Asia/Kolkata")!)
    let lateUTC = Date(timeIntervalSince1970: 1_790_380_800 + 20 * 3600) // 20:00 UTC = 01:30 next day in Kolkata
    let week = UsageDateRange.last(7, now: lateUTC, calendar: kolkata)
    let params = UsageDates.params(week, at: lateUTC)
    check(week.endKey == UsageDates.key(lateUTC.addingTimeInterval(19800), calendar: UsageDates.calendar(TimeZone(identifier: "UTC")!))
          && week.dayKeys.count == 7, "range keys in the device's zone (\(week.startKey)…\(week.endKey))")
    check(params["mode"]?.string == "specific" && params["timeZone"]?.string == "Asia/Kolkata" && params["utcOffset"]?.string == "UTC+5:30"
          && params["startDate"]?.string == week.startKey && params["endDate"]?.string == week.endKey, "date params (half-hour zone)")
    let la = UsageDates.calendar(TimeZone(identifier: "America/Los_Angeles")!)
    let laParams = UsageDates.params(.last(1, now: lateUTC, calendar: la), at: lateUTC)
    check(laParams["utcOffset"]?.string == "UTC-7" && laParams["startDate"] == laParams["endDate"], "date params (negative zone, one day)")
    check(UsageDates.date(fromKey: "2026-03-08", calendar: la).map { la.dateComponents([.year, .month, .day, .hour], from: $0) }
          == DateComponents(year: 2026, month: 3, day: 8, hour: 0), "YYYY-MM-DD parsed as local midnight")
    var custom = UsageRangeSelection(preset: .custom, now: lateUTC)
    custom.customStart = lateUTC.addingTimeInterval(86400 * 5)
    custom.customEnd = lateUTC.addingTimeInterval(86400 * 9)
    let clamped = custom.range(now: lateUTC, calendar: la)
    check(clamped.start == clamped.end && clamped.endKey == UsageDates.key(lateUTC, calendar: la), "custom range clamped to today")
    check(UsageRangeSelection().preset == .week && UsageRangePreset.allCases.map(\.label) == ["Today", "7 Days", "30 Days", "90 Days", "Custom"],
          "presets, 7 Days by default")
    let filled = UsageDay.filled(cost?.daily ?? [], range: UsageDateRange(start: UsageDates.date(fromKey: "2026-09-20")!, end: UsageDates.date(fromKey: "2026-09-26")!))
    check(filled.map(\.date) == ["2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26"]
          && filled[4].totals.totalTokens == 10 && filled[0].totals.isEmpty, "days zero-filled across the range")

    // Params: Gateway-wide calls use agentScope all; one session uses key + agentId, never agentScope.
    let wide = UsageRequests.sessions(week)
    check(UsageRequests.cost(week)["agentScope"]?.string == "all" && UsageRequests.cost(week)["key"] == nil, "usage.cost is Gateway-wide")
    check(wide["agentScope"]?.string == "all" && wide["groupBy"]?.string == "instance" && wide["limit"]?.int == 200
          && wide["includeContextWeight"]?.bool == false && wide["key"] == nil, "sessions.usage dashboard params")
    let single = UsageRequests.session(key: "agent:coder:main", agentId: nil, range: week)
    check(single["key"]?.string == "agent:coder:main" && single["agentId"]?.string == "coder" && single["agentScope"] == nil
          && single["limit"]?.int == 1 && single["startDate"]?.string == week.startKey, "single-session params")
    let logs = UsageRequests.logs(key: "global", agentId: nil)
    check(UsageRequests.timeseries(key: "agent:main:x", agentId: "ops") == ["key": "agent:main:x", "agentId": "ops"]
          && logs == ["key": "global", "limit": 200], "timeseries and logs params")

    // Formatting.
    check([0, 950, 12_345, 172_000, 1_200_000, 999_949_999, 3_400_000_000].map(UsageFormat.tokens)
          == ["0", "950", "12.3k", "172k", "1.2M", "999.9M", "3.4B"], "token formatting incl. B tier")
    check(UsageFormat.tokensSpoken(12_345, locale: en) == "12,345 tokens" && UsageFormat.tokensSpoken(1, locale: en) == "1 token", "tokens spoken")
    check([0, 0.004, 12.34, 99.994, 1234.4, 123_456].map { UsageFormat.currency($0, locale: en) }
          == ["$0.00", "<$0.01", "$12.34", "$99.99", "$1,234", "$123K"], "currency (\([0, 0.004, 12.34, 99.994, 1234.4, 123_456].map { UsageFormat.currency($0, locale: en) }))")
    check(UsageFormat.currency(1234, locale: Locale(identifier: "de_DE")).contains("1.234"), "currency grouping follows the locale")
    var unknown = UsageTotals()
    unknown.missingCostEntries = 4
    let unknownCost = UsageFormat.cost(unknown, locale: en)
    check(unknownCost.text == "—" && unknownCost.accessibilityLabel == "Cost unknown"
          && unknownCost.note == "The provider didn't report pricing for these requests.", "unknown cost")
    var partial = UsageTotals()
    partial.totalCost = 12.34
    partial.missingCostEntries = 3
    let partialCost = UsageFormat.cost(partial, locale: en)
    check(partialCost.text == "$12.34*" && partialCost.note == "Excludes 3 requests without pricing"
          && partialCost.accessibilityLabel == "$12.34, excludes 3 requests without pricing", "partial cost")
    check(UsageFormat.cost(.zero, locale: en).text == "$0.00" && UsageFormat.excludesNote(1) == "Excludes 1 request without pricing", "known cost")
    check([82.4, 0, 100, 150, -5, .nan].map(UsageFormat.percent) == ["82%", "0%", "100%", "100%+", "0%", "0%"]
          && UsageFormat.fraction(150) == 1 && UsageFormat.fraction(-3) == 0, "percent clamped")
    check([74.9, 75, 89.9, 90].map(UsageLevel.init(usedPercent:)) == [.normal, .warning, .warning, .critical], "quota levels")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let utc = TimeZone(identifier: "UTC")!
    check(UsageFormat.reset(now.addingTimeInterval(2 * 3600 + 14 * 60 + 5), now: now) == "Resets in 2h 14m"
          && UsageFormat.reset(now.addingTimeInterval(-5), now: now) == "Resets soon", "relative reset under a day")
    let absolute = UsageFormat.reset(now.addingTimeInterval(3 * 86400), now: now, locale: en, timeZone: utc)
    check(absolute.hasPrefix("Resets ") && !absolute.contains(" in ") && absolute.contains("Sep"), "absolute reset after a day (\(absolute))")
    check(UsageFormat.resetSpoken(now.addingTimeInterval(2 * 3600 + 60), now: now) == "resets in 2 hours"
          && UsageFormat.resetSpoken(now.addingTimeInterval(90), now: now) == "resets in 1 minute", "reset spoken")
    check(UsageFormat.range(start: "2026-09-20", end: "2026-09-26", locale: en)?.hasSuffix("Sep 26") == true
          && UsageFormat.range(start: "2026-09-20", end: "2026-09-26", locale: en)?.contains("Sep 20") == true
          && UsageFormat.day("2026-09-24", locale: en) == "Sep 24", "range and day labels")
    check(UsageFormat.amount(42.5, unit: "USD", locale: en) == "$42.50" && UsageFormat.amount(1200, unit: "credits", locale: en) == "1,200 credits"
          && UsageFormat.amount(3, unit: "EUR", locale: en).contains("€"), "billing units: ISO currency only")
    check(UsageFormat.shortDuration(3 * 86400 + 4 * 3600) == "3d 4h" && UsageFormat.shortDuration(20) == "<1m"
          && UsageFormat.duration(ms: 4_320_000) == "1h 12m", "durations")
    check(UsageFormat.middleTruncated("agent:main:dashboard:0123456789abcdef", limit: 24).count == 24
          && UsageFormat.middleTruncated("short") == "short", "middle truncation")

    // Sorting and breakdowns.
    let rows = result?.sessions ?? []
    check(UsageSessionSort.cost.sorted(rows).map(\.key) == ["agent:main:main", "agent:research:main", "agent:coder:main"]
          && UsageSessionSort.tokens.sorted(rows, ascending: true).last?.key == "agent:coder:main", "computing rows sort last")
    let buckets = (1...10).map { index -> UsageBreakdownItem in
        var totals = UsageTotals()
        totals.totalCost = Double(index)
        totals.totalTokens = index * 10
        return UsageBreakdownItem(id: "m\(index)", title: "m\(index)", totals: totals)
    }
    let top = UsageBreakdownItem.top(buckets, byCost: true)
    check(top.count == 9 && top.first?.id == "m10" && top.last?.isOther == true && top.last?.totals.totalCost == 3
          && top.last?.totals.totalTokens == 30, "top 8 plus Other")

    // Unsupported from hello.methods: no requests at all.
    var calls: [String] = []
    let legacy = UsageModel(methods: { ["sessions.list"] }) { method, _ in
        calls.append(method)
        return [:]
    }
    await legacy.load()
    await legacy.loadSession("agent:main:main")
    check(calls.isEmpty && legacy.isUnavailable && legacy.hasLoaded && !legacy.status.supported
          && legacy.detail("agent:main:main")?.timeseries.supported == false && legacy.detail("agent:main:main")?.logs.supported == false,
          "unsupported by hello.methods without requests")

    // Unsupported by UNKNOWN_METHOD, one method at a time; the others still load.
    let fixtures: [String: JSONValue] = [
        "usage.status": json(#"{"providers":[{"provider":"openai","windows":[]}]}"#),
        "usage.cost": json(#"{"daily":[],"totals":{"totalTokens":7}}"#),
        "sessions.usage": json(#"{"sessions":[],"totals":{"totalTokens":9}}"#),
        "sessions.usage.timeseries": json(#"{"points":[]}"#),
        "sessions.usage.logs": json(#"{"logs":[]}"#),
    ]
    for missing in UsageModel.methods {
        let model = UsageModel { method, _ in
            if method == missing { throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) }
            return fixtures[method] ?? [:]
        }
        await model.load()
        await model.loadSession("agent:main:main")
        let detail = model.detail("agent:main:main")
        let supported: [String: Bool] = [
            "usage.status": model.status.supported, "usage.cost": model.cost.supported,
            "sessions.usage": model.sessions.supported && detail?.totals.supported == true,
            "sessions.usage.timeseries": detail?.timeseries.supported == true, "sessions.usage.logs": detail?.logs.supported == true,
        ]
        check(supported.allSatisfy { $0.key == missing ? !$0.value : $0.value } && !model.isUnavailable && model.hasData,
              "\(missing) unsupported alone")
    }
    let costOnly = UsageModel { method, _ in
        if method == "sessions.usage" { throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil) }
        return fixtures[method] ?? [:]
    }
    await costOnly.load()
    check(costOnly.totals?.totalTokens == 7 && costOnly.daily?.count == 7, "totals and days fall back to usage.cost")

    // Errors: gateway messages, forbidden waits for Refresh, decode failures read plainly.
    calls = []
    let forbidden = UsageModel { method, _ in
        calls.append(method)
        if method == "usage.cost" {
            throw GatewayError.rpc(code: "FORBIDDEN", message: "Aggregate usage includes sessions hidden by your operator role; ask an administrator to review Gateway-wide usage.", details: nil)
        }
        if method == "usage.status" { throw GatewayError.rpc(code: "UNAVAILABLE", message: "provider refresh failed", details: nil) }
        return method == "sessions.usage" ? .string("nope") : [:]
    }
    await forbidden.load()
    check(forbidden.cost.isForbidden && forbidden.cost.loadState.error?.contains("ask an administrator") == true, "FORBIDDEN keeps the gateway message")
    check(forbidden.status.loadState.error == "provider refresh failed" && forbidden.sessions.loadState.error == UsageModel.decodeFailure
          && forbidden.sessions.hasLoaded, "errors per method, decode failure plain")
    calls = []
    await forbidden.setPreset(.month)
    check(!calls.contains("usage.cost") && !calls.contains("usage.status") && calls.contains("sessions.usage"),
          "range change skips forbidden usage.cost and range-free usage.status (\(calls))")
    calls = []
    await forbidden.refresh()
    check(calls.sorted() == ["sessions.usage", "usage.cost", "usage.status"], "Refresh retries everything")

    // Stale responses: the older range never lands over the newer one.
    let slow = UsageModel { method, params in
        if params["startDate"] == UsageRequests.cost(.last(7))["startDate"] { try await Task.sleep(for: .milliseconds(300)) }
        return method == "sessions.usage" ? ["startDate": params["startDate"] ?? .null, "endDate": params["endDate"] ?? .null, "sessions": []] : [:]
    }
    let first = Task { await slow.load() }
    try? await Task.sleep(for: .milliseconds(50))
    await slow.setPreset(.month)
    await first.value
    check(slow.sessions.value?.startDate == UsageDateRange.last(30).startKey && slow.selection.preset == .month
          && !slow.sessions.loadState.isRunning, "stale response dropped")

    // Drill-down: 30 days by default, cached per key, no transcript is empty.
    calls = []
    var sessionParams: [JSONValue] = []
    let drill = UsageModel { method, params in
        calls.append(method)
        switch method {
        case "sessions.usage":
            sessionParams.append(params)
            return ["sessions": .array([["key": params["key"] ?? .null, "usage": ["totalTokens": 5, "totalCost": 0.01]]])]
        case "sessions.usage.timeseries":
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "No transcript found for session: x", details: nil)
        default:
            return ["logs": .array([["timestamp": 1, "role": "user", "content": "old"], ["timestamp": 3, "role": "tool_result", "content": ["text": "x"]],
                                    ["timestamp": 2, "role": "assistant", "content": "new", "tokens": 12]])]
        }
    }
    drill.prepareSession("agent:coder:main")
    check(drill.detail("agent:coder:main")?.selection.preset == .month && drill.detail("agent:coder:main")?.agentId == "coder",
          "drill-down defaults to 30 days, agent from key")
    await drill.loadSession("agent:coder:main")
    let detail = drill.detail("agent:coder:main")
    check(detail?.row?.usage?.totals.totalTokens == 5 && sessionParams.first?["agentScope"] == nil
          && sessionParams.first?["agentId"]?.string == "coder" && sessionParams.first?["limit"]?.int == 1, "drill-down totals")
    check(detail?.timeseries.value?.points.isEmpty == true && detail?.timeseries.loadState == .idle, "no transcript is an empty timeseries")
    check(detail?.logs.value?.map(\.content) == ["{\"text\":\"x\"}", "new", "old"] && detail?.logs.value?.first?.role == .toolResult
          && detail?.logs.value?[1].tokens == 12, "logs newest first, non-text content as plain text")
    drill.prepareSession("agent:coder:main", selection: UsageRangeSelection(preset: .today))
    check(drill.detail("agent:coder:main")?.selection.preset == .today && drill.detail("agent:coder:main")?.logs.value?.count == 3
          && drill.detail("agent:coder:main")?.totals.value == nil, "new range keeps cached timeseries and logs")
    await drill.setSessionSelection("agent:coder:main", UsageRangeSelection(preset: .week))
    check(sessionParams.last?["startDate"]?.string == UsageDateRange.last(7).startKey && drill.detail("agent:coder:main")?.row != nil,
          "session range change reloads totals only")
}

/// The dashboard and a drill-down against the built-in demo.
@MainActor
func checkUsageDemo(_ gateway: GatewayStore) async {
    let usage = gateway.usage
    check(UsageModel.methods.allSatisfy { gateway.hello?.methods.contains($0) == true }, "demo advertises the usage methods")
    await usage.load()
    check(usage.status.supported && usage.cost.supported && usage.sessions.supported && usage.hasLoaded
          && usage.status.loadState == .idle && usage.cost.loadState == .idle && usage.sessions.loadState == .idle, "demo dashboard loads")
    let aggregates = usage.sessions.value?.aggregates
    check((usage.totals?.totalTokens ?? 0) > 0 && (usage.totals?.totalCost ?? 0) > 0 && (aggregates?.sessionCount ?? 0) >= 5
          && Set(aggregates?.byProvider.compactMap(\.provider) ?? []).count >= 2 && (aggregates?.byModel.count ?? 0) >= 3
          && Set(aggregates?.byAgent.map(\.key) ?? []) == Set(gateway.agents.map(\.id)), "demo aggregates across providers, models and agents")
    check(usage.daily?.count == 7 && usage.daily?.contains { $0.hasCategories } == true, "demo daily covers the week")
    check(aggregates?.byModel.contains { $0.totals.missingCostEntries > 0 && $0.totals.totalCost > 0 } == true
          && usage.sessions.value?.sessions.contains { $0.usage.map { $0.totals.costStatus == .unknown(missing: $0.totals.missingCostEntries) } == true } == true,
          "demo partial and unknown costs")
    let providers = usage.status.value?.providers ?? []
    check(providers.count >= 2 && providers.contains { $0.windows.contains { $0.usedPercent >= 90 && ($0.resetAt?.timeIntervalSinceNow ?? 9999) < 3600 } }
          && providers.contains { $0.error != nil }, "demo quotas: a red window resetting within the hour, a provider error")
    let budget = providers.flatMap(\.billing).first { $0.kind == .budget }
    check(budget != nil && (budget?.used ?? 0) > 0 && budget?.limit == 50 && budget?.unit == "USD", "demo usage.status has a budget (\(String(describing: budget?.used)))")
    await usage.setPreset(.month)
    let openAIMonth = usage.sessions.value?.aggregates.byProvider.first { $0.provider == "openai" }?.totals.totalCost ?? 0
    check(openAIMonth > 0 && abs((budget?.used ?? 0) - openAIMonth) < 0.01, "demo OpenAI budget matches 30 days of OpenAI spend (\(openAIMonth))")
    await usage.setPreset(.quarter)
    check(usage.sessions.value?.sessions.contains { $0.computing } == true && usage.cacheStatus?.isIncomplete == true, "demo long range still counting")
    await usage.setPreset(.week)

    let subagent = "agent:research:subagent:abc"
    await usage.loadSession(subagent)
    let unpriced = usage.detail(subagent)
    let unpricedTotals = unpriced?.row?.usage?.totals
    check(unpriced?.totals.loadState == .idle && (unpricedTotals?.totalTokens ?? 0) > 0
          && unpricedTotals?.costStatus == .unknown(missing: unpricedTotals?.missingCostEntries ?? 0) && (unpricedTotals?.missingCostEntries ?? 0) > 0
          && UsageFormat.cost(unpricedTotals ?? .zero).text == "—", "demo subagent drill-down: cost unknown")
    check(unpriced?.timeseries.value?.points.isEmpty == false && unpriced?.timeseries.loadState == .idle
          && unpriced?.logs.value?.isEmpty == false, "demo subagent drill-down: timeseries and logs")

    let key = "agent:main:main"
    usage.prepareSession(key, agentId: "main")
    await usage.loadSession(key)
    let detail = usage.detail(key)
    check((detail?.row?.usage?.totals.totalTokens ?? 0) > 0 && detail?.totals.loadState == .idle, "demo drill-down totals")
    check((detail?.timeseries.value?.points.count ?? 0) >= 40, "demo drill-down timeseries (\(detail?.timeseries.value?.points.count ?? 0))")
    check(detail?.logs.value?.count == 20 && Set(detail?.logs.value?.map(\.role) ?? []) == [.user, .assistant, .tool, .toolResult], "demo drill-down logs")
    let quiet = gateway.sessions.keys.first { key in !["agent:main:main", "agent:main:discord:channel:123", "agent:main:dashboard:trip",
                                                       "agent:research:main", "agent:research:dashboard:papers",
                                                       "agent:research:subagent:abc", "agent:coder:main"].contains(key) }
    if let quiet {
        await usage.loadSession(quiet)
        let empty = usage.detail(quiet)
        check(empty?.totals.loadState == .idle && (empty?.row?.usage?.totals.isEmpty ?? true)
              && empty?.timeseries.value?.points.isEmpty == true, "demo chat without usage shows zeros, not errors")
    }
}

/// Usage against the mock Gateway.
@MainActor
func checkUsageLive(_ gateway: GatewayStore) async {
    let usage = gateway.usage
    check(UsageModel.methods.allSatisfy { gateway.hello?.methods.contains($0) == true }, "hello advertises the usage methods")
    await usage.load()
    check(usage.status.supported && usage.cost.supported && usage.sessions.supported
          && usage.status.loadState == .idle && usage.cost.loadState == .idle && usage.sessions.loadState == .idle,
          "usage.status, usage.cost, sessions.usage load (\(usage.cost.loadState), \(usage.sessions.loadState))")
    let range = usage.range
    check(usage.sessions.value?.startDate == range.startKey && usage.sessions.value?.endDate == range.endKey, "gateway echoes the local range")
    check(usage.cost.value?.totals.totalTokens == usage.sessions.value?.totals.totalTokens && (usage.totals?.totalTokens ?? 0) > 0,
          "usage.cost and sessions.usage agree (agentScope all)")
    check(Set(usage.sessions.value?.aggregates.byAgent.map(\.key) ?? []) == ["main", "research", "coder"], "all agents counted")
    check((usage.status.value?.providers.count ?? 0) >= 2, "provider quotas")
    let key = "agent:coder:main"
    usage.prepareSession(key)
    await usage.loadSession(key)
    let detail = usage.detail(key)
    check(detail?.row?.key == key && (detail?.row?.usage?.modelUsage.count ?? 0) >= 2 && detail?.totals.loadState == .idle, "session totals via key + agentId")
    check((detail?.timeseries.value?.points.isEmpty == false) && detail?.logs.value?.count == 20, "session timeseries and logs")
    await usage.loadSession("agent:main:cron:disk-check")
    let quiet = usage.detail("agent:main:cron:disk-check")
    check(quiet?.totals.loadState == .idle && quiet?.row?.usage?.totals.isEmpty == true && quiet?.timeseries.value?.points.isEmpty == true
          && quiet?.timeseries.loadState == .idle, "chat without usage: zeros and an empty timeseries")
}

/// `--live-no-usage`: a Gateway without the usage methods (the mock with MOCK_NO_USAGE=1).
@MainActor
func runLiveNoUsage(url: String, token: String) async {
    let profile = GatewayProfile(name: "No usage", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor("connection without usage", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "connected to a gateway without usage")
    guard connected else { return }
    let usage = gateway.usage
    check(!UsageModel.methods.contains { gateway.hello?.methods.contains($0) == true }, "hello lacks the usage methods")
    await usage.load()
    await usage.loadSession("agent:main:main")
    let detail = usage.detail("agent:main:main")
    check(usage.isUnavailable && usage.hasLoaded && !usage.hasData && !usage.status.supported && !usage.cost.supported && !usage.sessions.supported
          && detail?.totals.supported == false && detail?.timeseries.supported == false && detail?.logs.supported == false,
          "every usage method unsupported, no crash")
    gateway.stop()
}
