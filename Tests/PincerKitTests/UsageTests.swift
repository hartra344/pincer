import Foundation
import Testing
@testable import PincerKit

private let en = Locale(identifier: "en_US")

/// Mutable state a scripted Gateway reads, changed between loads.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private func zone(_ id: String) -> Calendar { UsageDates.calendar(TimeZone(identifier: id)!) }

@Suite("Usage decoding")
struct UsageDecodingTests {
    @Test func fullTotals() {
        let totals = UsageTotals(Fixtures.json(#"""
        {"input":100,"output":50,"cacheRead":1000,"cacheWrite":10,"totalTokens":1160,"totalCost":1.25,
         "inputCost":0.25,"outputCost":0.5,"cacheReadCost":0.4,"cacheWriteCost":0.1,"missingCostEntries":0}
        """#))
        #expect(totals.input == 100 && totals.output == 50 && totals.cacheRead == 1000 && totals.cacheWrite == 10)
        #expect(totals.totalTokens == 1160 && totals.cacheTokens == 1010)
        #expect(totals.totalCost == 1.25 && totals.hasCostBreakdown && totals.costStatus == .known && !totals.isEmpty)
    }

    @Test func partialAndUnknownCost() {
        let partial = UsageTotals(Fixtures.json(#"{"totalTokens":10,"totalCost":2,"missingCostEntries":3,"missingCostByModel":{"ollama/qwen3":2,"lmstudio/x":1}}"#))
        #expect(partial.costStatus == .partial(missing: 3))
        #expect(partial.missingCostByModel == ["ollama/qwen3": 2, "lmstudio/x": 1])
        let unknown = UsageTotals(Fixtures.json(#"{"totalTokens":10,"missingCostEntries":4}"#))
        #expect(unknown.totalCost == 0 && unknown.costStatus == .unknown(missing: 4) && !unknown.isEmpty)
        #expect(!unknown.hasCostBreakdown)
    }

    @Test func missingFieldsDefault() {
        let summed = UsageTotals(Fixtures.json(#"{"input":1,"output":2,"cacheRead":3,"cacheWrite":4}"#))
        #expect(summed.totalTokens == 10 && summed.totalCost == 0 && summed.missingCostEntries == 0 && summed.missingCostByModel.isEmpty)
        // aggregates.daily rows name them `tokens` and `cost`.
        let daily = UsageTotals(Fixtures.json(#"{"tokens":42,"cost":0.5}"#))
        #expect(daily.totalTokens == 42 && daily.totalCost == 0.5)
        #expect(UsageTotals(nil) == .zero && UsageTotals(Fixtures.json("[1,2]")) == .zero && UsageTotals(.null) == .zero)
        #expect(UsageTotals.zero.isEmpty && UsageTotals.zero.costStatus == .known)
    }

    @Test func doubleTypedCountsRound() {
        let totals = UsageTotals(Fixtures.json(#"{"input":10.6,"totalTokens":99.4,"missingCostEntries":2.0}"#))
        #expect(totals.input == 11 && totals.totalTokens == 99 && totals.missingCostEntries == 2)
    }

    @Test func addingTotals() {
        var a = UsageTotals()
        a.input = 1
        a.totalTokens = 1
        a.totalCost = 0.5
        a.missingCostEntries = 1
        a.missingCostByModel = ["x/a": 1]
        var b = a
        b.missingCostByModel = ["x/a": 2, "x/b": 1]
        let sum = a + b
        #expect(sum.input == 2 && sum.totalTokens == 2 && sum.totalCost == 1 && sum.missingCostEntries == 2)
        #expect(sum.missingCostByModel == ["x/a": 3, "x/b": 1])
        #expect(a + .zero == a)
    }

    @Test func unknownFieldsIgnored() {
        let result = SessionsUsageResult(Fixtures.json(#"""
        {"updatedAt":1700000000000,"startDate":"2026-09-20","endDate":"2026-09-26","futureField":[1,2,3],
         "sessions":[{"key":"agent:main:main","scope":"instance","contextWeight":null,"origin":{"provider":"x"},
                      "usage":{"totalTokens":5,"latency":{"count":1},"dailyBreakdown":[{"date":"2026-09-20"}],"brandNew":true}}],
         "totals":{"totalTokens":5,"somethingElse":"x"},
         "aggregates":{"messages":{"total":1},"tools":{"totalCalls":2,"uniqueTools":1,"tools":[]},"byModel":[],"byProvider":[],
                       "byAgent":[],"byChannel":[],"daily":[],"latency":{"avgMs":1},"modelDaily":[],"byCreator":[]},
         "creatorOptions":[]}
        """#))
        #expect(result?.sessions.first?.usage?.totals.totalTokens == 5)
        #expect(result?.totals.totalTokens == 5 && result?.aggregates.toolCalls == 2)
        #expect(result?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func sessionRows() throws {
        let result = try #require(SessionsUsageResult(Fixtures.json(#"""
        {"sessions":[
          {"key":"agent:ops:dashboard:x","agentId":"research","modelProvider":"openai","model":"gpt-5",
           "providerOverride":"anthropic","modelOverride":"claude-opus-4-8","updatedAt":1700000000000,"usage":null},
          {"key":"global","usage":{"totalTokens":3,"lastActivity":1700000100000,"toolUsage":{"totalCalls":4},
           "messageCounts":{"user":2,"assistant":3}}},
          {"key":"agent:main:main","computing":true,"usage":{"totalTokens":1}},
          {"key":7}, "junk"
        ]}
        """#)))
        #expect(result.sessions.map(\.key) == ["agent:ops:dashboard:x", "global", "agent:main:main"])
        let first = result.sessions[0]
        #expect(first.agentId == "research", "the row's agentId wins over the key")
        #expect(first.provider == "anthropic" && first.model == "claude-opus-4-8", "overrides win")
        #expect(first.usage == nil && first.computing && first.lastActive == Date(timeIntervalSince1970: 1_700_000_000))
        let global = result.sessions[1]
        #expect(global.agentId == nil && !global.computing)
        #expect(global.lastActive == Date(timeIntervalSince1970: 1_700_000_100), "usage lastActivity beats updatedAt")
        #expect(global.usage?.toolCalls == 4 && global.usage?.messageCounts?.total == 5, "missing total is user + assistant")
        #expect(result.sessions[2].computing, "computing flag with usage still computing")
        #expect(result.totals.totalTokens == 4, "missing totals sum the rows")
        #expect(result.sessionCount == 3 && result.cacheStatus == nil && result.startDate == nil)
    }

    @Test func aggregates() {
        let aggregates = SessionsUsageAggregates(Fixtures.json(#"""
        {"sessionCount":40,"messages":{"total":9,"toolCalls":6},
         "byProvider":[{"provider":"anthropic","count":3,"totals":{"totalTokens":9}}],
         "byChannel":[{"channel":"discord","totals":{"totalTokens":2}},{"totals":{}},7],
         "daily":[{"date":"2026-09-24","tokens":10,"cost":1,"messages":3,"toolCalls":1,"errors":0},{"tokens":1}],
         "costDaily":[{"date":"2026-09-24","input":4,"output":6,"totalTokens":10,"totalCost":1}]}
        """#))
        #expect(aggregates.sessionCount == 40 && aggregates.toolCalls == 6, "tool calls fall back to messages.toolCalls")
        #expect(aggregates.byProvider.first?.provider == "anthropic" && aggregates.byProvider.first?.count == 3)
        #expect(aggregates.byChannel.map(\.key) == ["discord", ""])
        #expect(aggregates.daily.count == 1 && aggregates.daily[0].messages == 3 && !aggregates.daily[0].hasCategories)
        #expect(aggregates.costDaily?.first?.hasCategories == true && aggregates.costDaily?.first?.totals.input == 4)
        let empty = SessionsUsageAggregates(nil)
        #expect(empty.sessionCount == nil && empty.byModel.isEmpty && empty.costDaily == nil)
    }

    @Test func dayCategories() throws {
        let full = try #require(UsageDay(Fixtures.json(#"{"date":"2026-09-24","input":0,"output":1,"totalTokens":1}"#)))
        #expect(full.hasCategories)
        let flat = try #require(UsageDay(Fixtures.json(#"{"date":"2026-09-24","tokens":1,"cost":0}"#)))
        #expect(!flat.hasCategories && flat.totals.totalTokens == 1)
        #expect(UsageDay(Fixtures.json(#"{"tokens":1}"#)) == nil)
    }

    @Test func costSummary() throws {
        let cost = try #require(CostUsageSummary(Fixtures.json(#"""
        {"updatedAt":1700000000000,"days":2,"daily":[{"date":"2026-09-25","totalTokens":3,"totalCost":0.1}],
         "totals":{"totalTokens":3,"totalCost":0.1},
         "cacheStatus":{"status":"refreshing","cachedFiles":3,"pendingFiles":2,"staleFiles":1,"refreshedAt":1}}
        """#)))
        #expect(cost.days == 2 && cost.daily.count == 1 && cost.totals.totalTokens == 3)
        #expect(cost.cacheStatus?.status == "refreshing" && cost.cacheStatus?.pendingFiles == 2 && cost.cacheStatus?.isIncomplete == true)
        #expect(CostUsageSummary(Fixtures.json(#"{"cacheStatus":{"status":"fresh"}}"#))?.cacheStatus?.isIncomplete == false)
        #expect(CostUsageSummary(Fixtures.json(#"{"cacheStatus":{"pendingFiles":1}}"#))?.cacheStatus == nil)
        #expect(CostUsageSummary(Fixtures.json(#"{}"#))?.totals == .zero)
        #expect(CostUsageSummary(Fixtures.json(#""nope""#)) == nil && CostUsageSummary(.null) == nil)
    }

    @Test func providerStatus() throws {
        let status = try #require(UsageStatusSummary(Fixtures.json(#"""
        {"updatedAt":1700000000000,"refreshing":true,"providers":[
          {"provider":"openai","displayName":"OpenAI","summary":"Pro","accountEmail":"a@b.c",
           "windows":[{"usedPercent":150},"bad"],
           "billing":[{"type":"balance","amount":12.5,"unit":"USD"},{"type":"spend","amount":3,"unit":"USD","period":"month","resetAt":1700000000000},
                      {"type":"budget","label":"Team","used":5,"limit":10,"unit":"EUR"}],
           "costHistory":{"unit":"USD","daily":[]}},
          {"displayName":"Local"}
        ]}
        """#)))
        #expect(status.refreshing && status.providers.map(\.id) == ["openai", "Local"])
        let openai = status.providers[0]
        #expect(openai.windows.count == 1 && openai.windows[0].title == "Usage" && openai.windows[0].resetAt == nil)
        #expect(openai.billing.map(\.kind) == [.balance, .spend, .budget])
        #expect(openai.billing.map(\.title) == ["Balance", "Spend", "Team"])
        #expect(openai.billing[1].period == "month" && openai.billing[2].used == 5 && openai.billing[2].limit == 10)
        #expect(openai.summary == "Pro" && openai.accountEmail == "a@b.c" && openai.plan == nil)
        #expect(status.providers[1].displayName == "Local" && status.providers[1].windows.isEmpty)
        #expect(UsageStatusSummary(Fixtures.json(#"{}"#))?.providers.isEmpty == true)
    }

    @Test func timeseries() throws {
        let series = try #require(UsageTimeSeries(Fixtures.json(#"""
        {"sessionId":"s1","points":[
          {"timestamp":2000,"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":0.01,"cumulativeTokens":8,"cumulativeCost":0.03},
          {"timestamp":1000,"totalTokens":5,"cost":0.02,"cumulativeTokens":5,"cumulativeCost":0.02},
          {"timestamp":0,"totalTokens":1}
        ]}
        """#)))
        #expect(series.sessionId == "s1" && series.points.map(\.cumulativeTokens) == [5, 8], "sorted, zero timestamps dropped")
        #expect(series.points[1].totals.totalCost == 0.01 && series.points[1].totals.input == 1 && series.points[1].cumulativeCost == 0.03)
        #expect(UsageTimeSeries(.null) == .empty && UsageTimeSeries(Fixtures.json("[]")) == nil)
    }

    @Test func logs() throws {
        let logs = try #require(UsageLogEntry.decode(Fixtures.json(#"""
        {"logs":[{"role":"user","content":"a"},{"timestamp":5,"role":"assistant","content":"b","tokens":3,"cost":0.1},
                 {"timestamp":5,"role":"tool","content":"c"},{"role":"system","content":"d"},{"timestamp":9,"content":["x"]},"bad"]}
        """#)))
        #expect(logs.map(\.content) == ["[\"x\"]", "c", "b", "a", "d"], "newest first, ties by later index, untimed last in order")
        #expect(logs.map(\.role) == [.other("unknown"), .tool, .assistant, .user, .other("system")])
        #expect(logs[2].tokens == 3 && logs[2].cost == 0.1 && logs[0].role.label == "Unknown" && UsageLogEntry.Role.toolResult.label == "Tool result")
        #expect(UsageLogEntry.decode(Fixtures.json(#"[{"role":"user","content":"x"}]"#))?.count == 1, "a bare array")
        #expect(UsageLogEntry.decode(Fixtures.json(#"{}"#)) == [])
        #expect(UsageLogEntry.decode(Fixtures.json(#""x""#)) == nil)
    }
}

@Suite("Usage formatting")
struct UsageFormattingTests {
    @Test func tokens() {
        let counts = [0, 950, 999, 1000, 12_345, 99_999, 172_000, 999_499, 999_500, 1_200_000, 999_949_999, 999_950_000, 3_400_000_000, -12_345]
        #expect(counts.map(UsageFormat.tokens)
            == ["0", "950", "999", "1k", "12.3k", "100k", "172k", "999k", "1M", "1.2M", "999.9M", "1B", "3.4B", "-12.3k"])
        #expect(UsageFormat.tokensSpoken(12_345, locale: en) == "12,345 tokens")
        #expect(UsageFormat.tokensSpoken(1, locale: en) == "1 token" && UsageFormat.tokensSpoken(0, locale: en) == "0 tokens")
    }

    @Test func currencyPrecision() {
        let values: [Double] = [0, 0.001, 0.009, 0.01, 0.5, 12.346, 99.99, 100, 1234.4, 99_999, 100_000, 123_456, 1_234_567]
        #expect(values.map { UsageFormat.currency($0, locale: en) }
            == ["$0.00", "<$0.01", "<$0.01", "$0.01", "$0.50", "$12.35", "$99.99", "$100", "$1,234", "$99,999", "$100K", "$123K", "$1.23M"])
        #expect(UsageFormat.currency(-12.3, locale: en).contains("12.30"))
        #expect(UsageFormat.currency(1234, locale: Locale(identifier: "de_DE")).contains("1.234"))
    }

    @Test func axisCurrency() {
        #expect(UsageFormat.axisCurrency(0, locale: en) == "$0")
        #expect(UsageFormat.axisCurrency(1.25, locale: en) == "$1.25" && UsageFormat.axisCurrency(5, locale: en) == "$5")
        #expect(UsageFormat.axisCurrency(1200, locale: en) == "$1.2K")
    }

    @Test func costStates() {
        var totals = UsageTotals()
        totals.totalCost = 12.34
        let known = UsageFormat.cost(totals, locale: en)
        #expect(known.text == "$12.34" && known.amount == "$12.34" && known.note == nil && known.status == .known)

        totals.missingCostEntries = 1
        let partial = UsageFormat.cost(totals, locale: en)
        #expect(partial.text == "$12.34*" && partial.amount == "$12.34" && partial.status == .partial(missing: 1))
        #expect(partial.note == "Excludes 1 request without pricing")
        #expect(partial.accessibilityLabel == "$12.34, excludes 1 request without pricing")

        totals.totalCost = 0
        totals.missingCostEntries = 5
        let unknown = UsageFormat.cost(totals, locale: en)
        #expect(unknown.text == "—" && unknown.amount == nil && unknown.status == .unknown(missing: 5))
        #expect(unknown.accessibilityLabel == "Cost unknown" && unknown.note == UsageFormat.unknownCostHelp)
        #expect(UsageFormat.cost(.zero, locale: en).text == "$0.00", "nothing used is a known zero")
    }

    @Test func percentAndLevels() {
        #expect([0, 0.4, 49.5, 82.4, 100, 100.1, -1, .infinity, .nan].map(UsageFormat.percent)
            == ["0%", "0%", "50%", "82%", "100%", "100%+", "0%", "0%", "0%"])
        #expect(UsageFormat.fraction(50) == 0.5 && UsageFormat.fraction(250) == 1 && UsageFormat.fraction(.nan) == 0)
        #expect([0, 74.99, 75, 89.99, 90, 120].map(UsageLevel.init(usedPercent:)) == [.normal, .normal, .warning, .warning, .critical, .critical])
    }

    @Test func resets() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let utc = TimeZone(identifier: "UTC")!
        #expect(UsageFormat.reset(now.addingTimeInterval(45 * 60), now: now) == "Resets in 45m")
        #expect(UsageFormat.reset(now.addingTimeInterval(30), now: now) == "Resets in <1m")
        #expect(UsageFormat.reset(now.addingTimeInterval(86399), now: now) == "Resets in 23h 59m")
        #expect(UsageFormat.reset(now, now: now) == "Resets soon")
        let later = UsageFormat.reset(now.addingTimeInterval(86400), now: now, locale: en, timeZone: utc)
        #expect(later.hasPrefix("Resets Sep") && !later.contains("in "), "a day or more is absolute: \(later)")
        #expect(UsageFormat.resetSpoken(now.addingTimeInterval(3600), now: now) == "resets in 1 hour")
        #expect(UsageFormat.resetSpoken(now.addingTimeInterval(10), now: now) == "resets in 1 minute")
        #expect(UsageFormat.resetSpoken(now.addingTimeInterval(300), now: now) == "resets in 5 minutes")
        #expect(UsageFormat.resetSpoken(now.addingTimeInterval(-1), now: now) == "resets soon")
    }

    @Test func durations() {
        #expect(UsageFormat.shortDuration(0) == "<1m" && UsageFormat.shortDuration(3600) == "1h" && UsageFormat.shortDuration(86400) == "1d")
        #expect(UsageFormat.shortDuration(90061) == "1d 1h" && UsageFormat.duration(ms: 125_000) == "2m")
    }

    @Test func dayLabels() {
        let la = zone("America/Los_Angeles")
        #expect(UsageFormat.day("2026-09-24", locale: en, calendar: la) == "Sep 24")
        #expect(UsageFormat.day("garbage", locale: en) == "garbage")
        #expect(UsageFormat.range(start: "2026-09-26", end: "2026-09-26", locale: en, calendar: la)?.hasPrefix("Sep 26") == true)
        #expect(UsageFormat.range(start: "2025-12-28", end: "2026-01-03", locale: en, calendar: la)?.contains("2025") == true, "years shown across years")
        #expect(UsageFormat.range(start: "x", end: "2026-01-03", locale: en) == nil)
    }

    @Test func amounts() {
        #expect(UsageFormat.amount(0.004, unit: "usd", locale: en) == "<$0.01", "USD follows currency rules, any case")
        #expect(UsageFormat.amount(3.5, unit: "", locale: en) == "3.5")
        #expect(UsageFormat.amount(10, unit: "tok", locale: en) == "10 tok", "three letters but not ISO 4217")
    }

    @Test func middleTruncation() {
        let key = "agent:main:dashboard:0123456789abcdef"
        let short = UsageFormat.middleTruncated(key, limit: 20)
        #expect(short.count == 20 && short.hasPrefix("agent:mai") && short.hasSuffix("abcdef") && short.contains("…"))
        #expect(UsageFormat.middleTruncated(key, limit: 3) == key && UsageFormat.middleTruncated("abc", limit: 3) == "abc")
    }
}

@Suite("Usage date ranges")
struct UsageDateRangeTests {
    @Test func lastDays() {
        let utc = zone("UTC")
        let now = Date(timeIntervalSince1970: 1_767_225_600 + 3600) // 2026-01-01T01:00Z
        let week = UsageDateRange.last(7, now: now, calendar: utc)
        #expect(week.startKey == "2025-12-26" && week.endKey == "2026-01-01" && week.dayKeys.count == 7)
        #expect(week.dayKeys.first == "2025-12-26" && week.dayKeys.last == "2026-01-01")
        #expect(UsageDateRange.last(1, now: now, calendar: utc).dayKeys == ["2026-01-01"])
        #expect(UsageDateRange.last(0, now: now, calendar: utc).dayKeys == ["2026-01-01"], "at least one day")
        #expect(UsageDateRange.last(90, now: now, calendar: utc).dayKeys.count == 90)
    }

    @Test func localDayNotUTC() {
        let now = Date(timeIntervalSince1970: 1_767_225_600 + 3600) // 2026-01-01T01:00Z = Dec 31, 17:00 in LA
        #expect(UsageDateRange.last(1, now: now, calendar: zone("America/Los_Angeles")).endKey == "2025-12-31")
        #expect(UsageDateRange.last(1, now: now, calendar: zone("Asia/Tokyo")).endKey == "2026-01-01")
        #expect(UsageDateRange.last(1, now: now, calendar: zone("Pacific/Kiritimati")).endKey == "2026-01-01")
    }

    @Test func dstDays() {
        let la = zone("America/Los_Angeles")
        let spring = UsageDateRange(start: UsageDates.date(fromKey: "2026-03-07", calendar: la)!,
                                    end: UsageDates.date(fromKey: "2026-03-09", calendar: la)!, calendar: la)
        #expect(spring.dayKeys == ["2026-03-07", "2026-03-08", "2026-03-09"], "the 23-hour day isn't skipped")
        let fall = UsageDateRange(start: UsageDates.date(fromKey: "2026-10-31", calendar: la)!,
                                  end: UsageDates.date(fromKey: "2026-11-02", calendar: la)!, calendar: la)
        #expect(fall.dayKeys == ["2026-10-31", "2026-11-01", "2026-11-02"], "the 25-hour day isn't doubled")
    }

    @Test func endBeforeStart() {
        let utc = zone("UTC")
        let range = UsageDateRange(start: UsageDates.date(fromKey: "2026-09-26", calendar: utc)!,
                                   end: UsageDates.date(fromKey: "2026-09-20", calendar: utc)!, calendar: utc)
        #expect(range.startKey == "2026-09-26" && range.endKey == "2026-09-26")
    }

    @Test func keys() {
        let utc = zone("UTC")
        #expect(UsageDates.date(fromKey: "2026-02-03", calendar: utc) == Date(timeIntervalSince1970: 1_770_076_800))
        #expect(UsageDates.date(fromKey: "2026-02", calendar: utc) == nil && UsageDates.date(fromKey: "a-b-c", calendar: utc) == nil)
        #expect(UsageDates.key(Date(timeIntervalSince1970: 1_770_076_800 - 1), calendar: utc) == "2026-02-02")
        #expect(UsageDates.calendar(TimeZone(identifier: "Asia/Tokyo")!).identifier == .gregorian)
    }

    @Test func utcOffsets() {
        #expect(UsageDates.utcOffset(secondsFromGMT: 0) == "UTC+0")
        #expect(UsageDates.utcOffset(secondsFromGMT: 3600 * 14) == "UTC+14")
        #expect(UsageDates.utcOffset(secondsFromGMT: -3600 * 11) == "UTC-11")
        #expect(UsageDates.utcOffset(secondsFromGMT: 19800) == "UTC+5:30")
        #expect(UsageDates.utcOffset(secondsFromGMT: -12600) == "UTC-3:30")
        #expect(UsageDates.utcOffset(secondsFromGMT: 20700) == "UTC+5:45")
    }

    @Test func paramsUseTheOffsetAtNow() {
        let la = zone("America/Los_Angeles")
        let winter = Date(timeIntervalSince1970: 1_767_225_600) // January: PST
        let summer = Date(timeIntervalSince1970: 1_782_864_000) // July: PDT
        #expect(UsageDates.params(.last(7, now: winter, calendar: la), at: winter)["utcOffset"] == "UTC-8")
        #expect(UsageDates.params(.last(7, now: summer, calendar: la), at: summer)["utcOffset"] == "UTC-7")
        let params = UsageDates.params(.last(7, now: summer, calendar: la), at: summer)
        #expect(params["mode"] == "specific" && params["timeZone"] == "America/Los_Angeles")
        #expect(Set(params.keys) == ["startDate", "endDate", "mode", "timeZone", "utcOffset"])
    }

    @Test func selection() {
        let utc = zone("UTC")
        let now = Date(timeIntervalSince1970: 1_790_380_800) // 2026-09-26T00:00Z
        for preset in UsageRangePreset.allCases where preset != .custom {
            let range = UsageRangeSelection(preset: preset, now: now).range(now: now, calendar: utc)
            #expect(range.dayKeys.count == preset.days && range.endKey == "2026-09-26", "\(preset)")
        }
        var custom = UsageRangeSelection(preset: .custom, now: now)
        custom.customStart = now.addingTimeInterval(-86400 * 10)
        custom.customEnd = now.addingTimeInterval(-86400 * 3)
        #expect(custom.range(now: now, calendar: utc).startKey == "2026-09-16" && custom.range(now: now, calendar: utc).endKey == "2026-09-23")
        custom.customStart = now.addingTimeInterval(-86400 * 2)
        custom.customEnd = now.addingTimeInterval(-86400 * 5)
        let flipped = custom.range(now: now, calendar: utc)
        #expect(flipped.startKey == "2026-09-21" && flipped.endKey == "2026-09-21", "a start after the end moves to the end")
        #expect(UsageRangeSelection(now: now).preset == .week && UsageRangePreset.custom.days == nil)
    }

    @Test func filledDays() {
        let utc = zone("UTC")
        let range = UsageDateRange(start: UsageDates.date(fromKey: "2026-09-24", calendar: utc)!,
                                   end: UsageDates.date(fromKey: "2026-09-26", calendar: utc)!, calendar: utc)
        var first = UsageDay(date: "2026-09-25", hasCategories: false)
        first.totals.totalTokens = 3
        var duplicate = UsageDay(date: "2026-09-25", hasCategories: false)
        duplicate.totals.totalTokens = 99
        let outside = UsageDay(date: "2026-09-01", hasCategories: false)
        let filled = UsageDay.filled([first, duplicate, outside], range: range)
        #expect(filled.map(\.date) == ["2026-09-24", "2026-09-25", "2026-09-26"])
        #expect(filled[1].totals.totalTokens == 3 && filled.allSatisfy { !$0.hasCategories }, "zero days match the rest")
        #expect(UsageDay.filled([], range: range).allSatisfy { $0.hasCategories && $0.totals.isEmpty })
    }
}

@Suite("Usage requests")
struct UsageRequestTests {
    let range = UsageDateRange.last(7, now: Date(timeIntervalSince1970: 1_790_380_800), calendar: zone("UTC"))

    @Test func gatewayWide() {
        let cost = UsageRequests.cost(self.range)
        #expect(cost["agentScope"] == "all" && absent(cost["key"]) && absent(cost["agentId"]) && cost["startDate"] == "2026-09-20")
        let sessions = UsageRequests.sessions(self.range)
        #expect(sessions["agentScope"] == "all" && absent(sessions["key"]) && absent(sessions["agentId"]))
        #expect(sessions["limit"]?.int == UsageRequests.sessionLimit && sessions["groupBy"] == "instance" && sessions["includeContextWeight"] == false)
        #expect(UsageRequests.sessions(self.range, limit: 0)["limit"]?.int == 1 && UsageRequests.sessions(self.range, limit: 5000)["limit"]?.int == 1000)
    }

    @Test func oneSession() {
        let params = UsageRequests.session(key: "agent:coder:dashboard:x", agentId: nil, range: self.range)
        #expect(params["key"] == "agent:coder:dashboard:x" && params["agentId"] == "coder" && absent(params["agentScope"]))
        #expect(params["limit"]?.int == 1 && params["endDate"] == "2026-09-26" && params["mode"] == "specific")
        #expect(UsageRequests.session(key: "agent:coder:main", agentId: "ops", range: self.range)["agentId"] == "ops")
        #expect(absent(UsageRequests.session(key: "global", agentId: nil, range: self.range)["agentId"]))
        #expect(absent(UsageRequests.timeseries(key: "global", agentId: nil)["agentId"]))
        let logs = UsageRequests.logs(key: "agent:main:main", agentId: nil, limit: 9999)
        #expect(logs["agentId"] == "main" && logs["limit"]?.int == 1000 && absent(logs["agentScope"]) && absent(logs["startDate"]))
    }
}

@Suite("Usage sorting")
struct UsageSortingTests {
    func row(_ key: String, cost: Double? = nil, tokens: Int = 0, last: Double? = nil) -> SessionUsageRow {
        var usage: JSONValue = .null
        if let cost { usage = ["totalCost": .number(cost), "totalTokens": .number(Double(tokens)), "lastActivity": last.map(JSONValue.number) ?? .null] }
        return SessionUsageRow(["key": .string(key), "usage": usage])!
    }

    @Test func sorts() {
        let rows = [self.row("a", cost: 1, tokens: 10, last: 3000), self.row("pending"), self.row("b", cost: 1, tokens: 50, last: 1000),
                    self.row("c", cost: 5, tokens: 1, last: 2000)]
        #expect(UsageSessionSort.cost.sorted(rows).map(\.key) == ["c", "b", "a", "pending"], "cost ties broken by tokens")
        #expect(UsageSessionSort.cost.sorted(rows, ascending: true).map(\.key) == ["a", "b", "c", "pending"])
        #expect(UsageSessionSort.tokens.sorted(rows).map(\.key) == ["b", "a", "c", "pending"])
        #expect(UsageSessionSort.recent.sorted(rows).map(\.key) == ["a", "c", "b", "pending"])
    }

    @Test func breakdown() {
        func item(_ id: String, cost: Double, tokens: Int) -> UsageBreakdownItem {
            var totals = UsageTotals()
            totals.totalCost = cost
            totals.totalTokens = tokens
            return UsageBreakdownItem(id: id, title: id, totals: totals)
        }
        let items = [item("a", cost: 1, tokens: 900), item("b", cost: 3, tokens: 10), item("c", cost: 1, tokens: 1000)]
        #expect(UsageBreakdownItem.top(items, byCost: true).map(\.id) == ["b", "c", "a"])
        #expect(UsageBreakdownItem.top(items, byCost: false).map(\.id) == ["c", "a", "b"])
        let top = UsageBreakdownItem.top(items, byCost: true, limit: 1)
        #expect(top.map(\.id) == ["b", "__other__"] && top[1].isOther && top[1].totals.totalTokens == 1900 && top[1].totals.totalCost == 2)
        #expect(UsageBreakdownItem.top(items, byCost: true, limit: 3).allSatisfy { !$0.isOther })
    }
}

@MainActor
@Suite("Usage model")
struct UsageModelTests {
    static let fixtures: [String: JSONValue] = [
        "usage.status": Fixtures.json(#"{"providers":[{"provider":"openai","windows":[]}]}"#),
        "usage.cost": Fixtures.json(#"{"daily":[{"date":"2026-09-24","totalTokens":7}],"totals":{"totalTokens":7}}"#),
        "sessions.usage": Fixtures.json(#"{"sessions":[{"key":"agent:main:main","usage":{"totalTokens":9}}],"totals":{"totalTokens":9}}"#),
        "sessions.usage.timeseries": Fixtures.json(#"{"points":[{"timestamp":1}]}"#),
        "sessions.usage.logs": Fixtures.json(#"{"logs":[{"role":"user","content":"x"}]}"#),
    ]

    static func supported(_ model: UsageModel, _ key: String) -> [String: Bool] {
        let detail = model.detail(key)
        return [
            "usage.status": model.status.supported, "usage.cost": model.cost.supported,
            "sessions.usage": model.sessions.supported && detail?.totals.supported == true,
            "sessions.usage.timeseries": detail?.timeseries.supported == true,
            "sessions.usage.logs": detail?.logs.supported == true,
        ]
    }

    @Test(arguments: UsageModel.methods)
    func missingFromHello(_ missing: String) async {
        var calls: [String] = []
        let advertised = Set(UsageModel.methods).subtracting([missing]).union(["sessions.list"])
        let model = UsageModel(methods: { advertised }) { method, _ in
            calls.append(method)
            return Self.fixtures[method] ?? [:]
        }
        await model.load()
        await model.loadSession("agent:main:main")
        #expect(!calls.contains(missing), "no request for an unadvertised method")
        #expect(Self.supported(model, "agent:main:main").allSatisfy { $0.key == missing ? !$0.value : $0.value })
        #expect(!model.isUnavailable && model.hasLoaded && model.hasData)
    }

    @Test(arguments: UsageModel.methods, ["UNKNOWN_METHOD", "METHOD_NOT_FOUND", "INVALID_REQUEST"])
    func unknownMethodError(_ missing: String, code: String) async {
        let model = UsageModel { method, _ in
            if method == missing { throw GatewayError.rpc(code: code, message: "unknown method: \(method)", details: nil) }
            return Self.fixtures[method] ?? [:]
        }
        await model.load()
        await model.loadSession("agent:main:main")
        #expect(Self.supported(model, "agent:main:main").allSatisfy { $0.key == missing ? !$0.value : $0.value })
        #expect(!model.isUnavailable && model.hasData)
    }

    @Test func emptyHelloMethodsMeansUnknown() async {
        var calls: [String] = []
        let model = UsageModel(methods: { [] }) { method, _ in
            calls.append(method)
            return Self.fixtures[method] ?? [:]
        }
        await model.load()
        #expect(Set(calls) == ["usage.status", "usage.cost", "sessions.usage"] && model.status.supported)
    }

    @Test func allUnsupported() async {
        let model = UsageModel { method, _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) }
        await model.load()
        #expect(model.isUnavailable && model.hasLoaded && !model.hasData && !model.isLoading && model.totals == nil && model.daily == nil)
    }

    @Test func unsupportedComesBack() async {
        let missing = Box(true)
        let model = UsageModel { method, _ in
            if missing.value { throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "", details: nil) }
            return Self.fixtures[method] ?? [:]
        }
        await model.load()
        #expect(model.isUnavailable)
        missing.value = false
        await model.refresh()
        #expect(!model.isUnavailable && model.status.supported && model.cost.value != nil)
    }

    @Test func errorsStayPerMethod() async {
        let model = UsageModel { method, _ in
            switch method {
            case "usage.status": throw GatewayError.rpc(code: "UNAVAILABLE", message: "", details: nil)
            case "usage.cost": throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.read",
                                                       details: ["code": "MISSING_SCOPE"])
            default: return Self.fixtures[method] ?? [:]
            }
        }
        await model.load()
        #expect(model.status.loadState.error == "The gateway couldn't load usage." && model.status.supported)
        #expect(!model.cost.isForbidden && model.cost.loadState.error == "missing scope: operator.read", "a missing scope isn't the role refusal")
        #expect(model.sessions.value?.totals.totalTokens == 9 && model.totals?.totalTokens == 9)
    }

    @Test func decodeFailureKeepsOldValue() async {
        let broken = Box(false)
        let model = UsageModel { method, _ in broken.value ? .array([]) : Self.fixtures[method] ?? [:] }
        await model.load()
        broken.value = true
        await model.refresh()
        #expect(model.cost.loadState.error == UsageModel.decodeFailure && model.cost.value?.totals.totalTokens == 7)
        #expect(model.status.value != nil && model.hasData)
    }

    @Test func dailyFallbacks() async {
        let now = Date(timeIntervalSince1970: 1_790_380_800 + 12 * 3600)
        let cost = Box<JSONValue>(["daily": [["date": "2026-09-24", "input": 1, "totalTokens": 1]]])
        let sessions = Box<JSONValue>(["startDate": "2026-09-24", "endDate": "2026-09-26",
                                   "aggregates": ["daily": [["date": "2026-09-25", "tokens": 5, "cost": 0]],
                                                  "costDaily": [["date": "2026-09-26", "input": 2, "totalTokens": 2]]]])
        let model = UsageModel(now: { now }) { method, _ in method == "usage.cost" ? cost.value : method == "sessions.usage" ? sessions.value : [:] }
        await model.load()
        #expect(model.displayedRange.dayKeys == ["2026-09-24", "2026-09-25", "2026-09-26"], "the gateway's range")
        #expect(model.daily?.map(\.totals.totalTokens) == [1, 0, 0], "usage.cost first")
        cost.value = .string("x")
        await model.refresh()
        #expect(model.daily?.map(\.totals.totalTokens) == [1, 0, 0], "a failed refresh keeps the last days")

        let noCost = UsageModel(now: { now }) { method, _ in
            if method == "usage.cost" { throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "", details: nil) }
            return method == "sessions.usage" ? sessions.value : [:]
        }
        await noCost.load()
        #expect(noCost.daily?.map(\.totals.totalTokens) == [0, 0, 2] && noCost.daily?.allSatisfy(\.hasCategories) == true, "then costDaily")
        sessions.value = ["startDate": "2026-09-24", "endDate": "2026-09-26", "aggregates": ["daily": [["date": "2026-09-25", "tokens": 5, "cost": 0]]]]
        await noCost.refresh()
        #expect(noCost.daily?.map(\.totals.totalTokens) == [0, 5, 0] && noCost.daily?.contains(where: \.hasCategories) == false, "then daily")
    }

    @Test func cacheStatusPrefersIncomplete() async {
        let model = UsageModel { method, _ in
            switch method {
            case "usage.cost": ["cacheStatus": ["status": "stale", "staleFiles": 2]]
            case "sessions.usage": ["cacheStatus": ["status": "fresh"]]
            default: [:]
            }
        }
        await model.load()
        #expect(model.cacheStatus?.status == "stale" && model.cacheStatus?.staleFiles == 2)
    }

    @Test func staleSessionTotalsDropped() async throws {
        let key = "agent:main:main"
        let model = UsageModel { method, params in
            guard method == "sessions.usage" else { return Self.fixtures[method] ?? [:] }
            let today = params["startDate"] == params["endDate"]
            if !today { try await Task.sleep(for: .milliseconds(300)) }
            return ["sessions": [["key": .string(key), "usage": ["totalTokens": today ? 1 : 30]]]]
        }
        model.prepareSession(key)
        let slow = Task { await model.loadSessionTotals(key) }
        try await Task.sleep(for: .milliseconds(50))
        await model.setSessionSelection(key, UsageRangeSelection(preset: .today))
        await slow.value
        #expect(model.detail(key)?.row?.usage?.totals.totalTokens == 1 && model.detail(key)?.totals.loadState == .idle)
    }

    @Test func drillDownsAreIndependent() async {
        let model = UsageModel { method, params in
            if method == "sessions.usage.logs", params["key"] == "agent:coder:main" {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Invalid session key: agent:coder:main", details: nil)
            }
            return Self.fixtures[method] ?? [:]
        }
        await model.loadSession("agent:main:main")
        await model.loadSession("agent:coder:main")
        #expect(model.detail("agent:main:main")?.logs.value?.count == 1)
        #expect(model.detail("agent:coder:main")?.logs.loadState.error == "Invalid session key: agent:coder:main")
        #expect(model.detail("agent:coder:main")?.agentId == "coder" && model.detail("agent:coder:main")?.timeseries.value?.points.count == 1)
    }

    @Test func otherTimeseriesErrorsFail() async {
        let model = UsageModel { method, _ in
            if method == "sessions.usage.timeseries" { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Invalid session key: x", details: nil) }
            return Self.fixtures[method] ?? [:]
        }
        await model.loadTimeseries("x")
        #expect(model.detail("x")?.timeseries.value == nil && model.detail("x")?.timeseries.loadState.error == "Invalid session key: x")
    }

    @Test func sameSelectionDoesNothing() async {
        var calls = 0
        let model = UsageModel { _, _ in
            calls += 1
            return [:]
        }
        await model.setSelection(model.selection)
        #expect(calls == 0)
        await model.setPreset(.today)
        #expect(calls == 3 && model.selection.preset == .today, "first load includes usage.status")
        await model.setPreset(.week)
        #expect(calls == 5, "usage.status isn't range-bound")
    }
}
