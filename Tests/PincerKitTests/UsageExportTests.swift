import Foundation
import Testing
@testable import PincerKit

private let utc = UsageDates.calendar(TimeZone(identifier: "UTC")!)
// 2026-10-16T17:18:10.795Z
private let stamp = Date(timeIntervalSince1970: 1_792_171_090.795)
private let stampMs: Double = 1_792_171_090_795

private func fixture(partial: Bool = false) -> JSONValue {
    var result: JSONValue = [
        "updatedAt": 1_792_171_090_795,
        "startDate": "2026-10-10", "endDate": "2026-10-16",
        "sessions": [
            ["key": "agent:main:main", "label": "Main, \"quoted\"", "agentId": "main", "channel": "webchat",
             "modelProvider": "anthropic", "model": "claude-opus", "updatedAt": .number(stampMs),
             "contextWeight": ["total": 12],
             "usage": ["durationMs": 5000, "input": 100, "output": 50, "cacheRead": 10, "cacheWrite": 5,
                       "totalTokens": 165, "totalCost": 0.00001,
                       "messageCounts": ["total": 4, "errors": 1, "toolCalls": 2]]],
            ["key": "agent:main:cron:x", "providerOverride": "openai", "modelOverride": "gpt-x",
             "usage": ["input": 1, "output": 2, "totalTokens": 3, "totalCost": 12,
                       "usageReport": ["state": "unavailable"],
                       "messageCounts": ["total": 1, "errors": 0, "toolCalls": 0]]],
        ],
        "totals": ["totalTokens": 168, "totalCost": 12.00001],
        "aggregates": [
            "sessionCount": 2,
            "costDaily": [
                ["date": "2026-10-15", "input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4, "totalTokens": 10,
                 "inputCost": 0.5, "outputCost": 0.25, "cacheReadCost": 0.00001, "cacheWriteCost": 0, "totalCost": 0.75001],
                ["date": "2026-10-16", "input": 9, "totalTokens": 9, "totalCost": 1,
                 "usageReport": ["state": "unavailable"]],
            ],
        ],
    ]
    if partial {
        result = result.setting("cacheStatus", ["status": "partial", "cachedFiles": 1, "pendingFiles": 2, "staleFiles": 0])
    }
    return result
}

private extension JSONValue {
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        var object = self.object ?? [:]
        object[key] = value
        return .object(object)
    }
}

@Suite("Usage export")
struct UsageExportTests {
    @Test func sessionsCSVHeaderAndRows() {
        let csv = UsageExport.sessionsCSV(fixture()["sessions"]?.array ?? [])
        let lines = csv.components(separatedBy: "\n")
        #expect(lines[0] == "key,label,agentId,channel,provider,model,updatedAt,durationMs,messages,errors,toolCalls,"
            + "inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens,totalTokens,totalCost")
        #expect(lines[1] == "agent:main:main,\"Main, \"\"quoted\"\"\",main,webchat,anthropic,claude-opus,"
            + "2026-10-16T17:18:10.795Z,5000,4,1,2,100,50,10,5,165,0.00001")
        // Fallbacks, missing updatedAt/label, and usageReport unavailable blanks every numeric usage cell.
        #expect(lines[2] == "agent:main:cron:x,,,,openai,gpt-x,,,1,0,0,,,,,,")
        #expect(lines.count == 3, "no trailing newline")
        #expect(!csv.hasPrefix("\u{FEFF}"))
    }

    @Test func dailyCSVFromCostDaily() {
        let csv = UsageExport.dailyCSV(fixture()["aggregates"]?["costDaily"]?.array ?? [])
        let lines = csv.components(separatedBy: "\n")
        #expect(lines[0] == "date,inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens,totalTokens,inputCost,"
            + "outputCost,cacheReadCost,cacheWriteCost,totalCost")
        #expect(lines[1] == "2026-10-15,1,2,3,4,10,0.5,0.25,0.00001,0,0.75001")
        #expect(lines[2] == "2026-10-16,,,,,,,,,,")
        #expect(lines.count == 3)
    }

    @Test func cellEscaping() {
        #expect(UsageExport.csvCell("=SUM(1)") == "'=SUM(1)")
        #expect(UsageExport.csvCell("  \t=SUM(1)") == "'  \t=SUM(1)")
        #expect(UsageExport.csvCell("+1") == "'+1")
        #expect(UsageExport.csvCell("-1") == "'-1")
        #expect(UsageExport.csvCell("@x") == "'@x")
        for lead in ["＝", "＋", "－", "＠"] {
            #expect(UsageExport.csvCell(.string(lead + "a")) == "'" + lead + "a")
        }
        #expect(UsageExport.csvCell("a=b") == "a=b")
        #expect(UsageExport.csvCell(.number(-1)) == "-1", "numbers aren't neutralized")
        #expect(UsageExport.csvCell("a,b") == "\"a,b\"")
        #expect(UsageExport.csvCell("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(UsageExport.csvCell("a\nb") == "\"a\nb\"")
        #expect(UsageExport.csvCell("a\rb") == "\"a\rb\"")
        #expect(UsageExport.csvCell("=a,b") == "\"'=a,b\"")
        #expect(UsageExport.csvCell(nil) == "")
        #expect(UsageExport.csvCell(.null) == "")
        #expect(UsageExport.csvCell(.number(5)) == "5")
        #expect(UsageExport.csvCell(.number(5.0)) == "5")
        #expect(UsageExport.csvCell(.number(0.00001)) == "0.00001")
        #expect(UsageExport.csvCell(.number(0.000001)) == "0.000001")
        #expect(UsageExport.csvCell(.number(1.5)) == "1.5")
        #expect(UsageExport.csvCell(.number(1_000_000)) == "1000000")
    }

    @Test func formulaNeutralizationInRows() {
        let rows: [JSONValue] = [["key": "=cmd", "label": "-x", "agentId": "＠a"]]
        let line = UsageExport.sessionsCSV(rows).components(separatedBy: "\n")[1]
        #expect(line.hasPrefix("'=cmd,'-x,'＠a,"))
    }

    @Test func jsonShape() throws {
        let result = fixture()
        let data = UsageExport.json(result)
        let parsed = try JSONValue.decode(data)
        #expect(Set(parsed.object?.keys.map { $0 } ?? []) == ["sessions", "totals", "aggregates", "daily"])
        #expect(parsed["daily"] == result["aggregates"]?["costDaily"])
        #expect(parsed["sessions"]?[0]?["contextWeight"]?["total"]?.int == 12, "unknown fields survive")
        #expect(parsed["sessions"] == result["sessions"])
        #expect(parsed["totals"] == result["totals"])
        #expect(parsed["aggregates"] == result["aggregates"])
        // No costDaily → [].
        let bare: JSONValue = ["sessions": [], "totals": [:], "aggregates": ["sessionCount": 0]]
        #expect(try JSONValue.decode(UsageExport.json(bare))["daily"] == [])
    }

    @Test func fileNames() {
        #expect(UsageExport.fileName(.sessionsCSV, date: stamp, calendar: utc) == "openclaw-usage-sessions-2026-10-16.csv")
        #expect(UsageExport.fileName(.dailyCSV, date: stamp, calendar: utc) == "openclaw-usage-daily-2026-10-16.csv")
        #expect(UsageExport.fileName(.json, date: stamp, calendar: utc) == "openclaw-usage-2026-10-16.json")
        let tokyo = UsageDates.calendar(TimeZone(identifier: "Pacific/Kiritimati")!)
        #expect(UsageExport.fileName(.json, date: stamp, calendar: tokyo) == "openclaw-usage-2026-10-17.json", "local day")
    }

    @Test func requestParams() {
        let range = UsageDateRange.last(7, now: stamp, calendar: utc)
        for format in UsageExportFormat.allCases {
            let params = UsageExport.params(format, range: range, at: stamp)
            #expect(params["agentScope"]?.string == "all")
            #expect(params["groupBy"]?.string == "instance")
            #expect(params["startDate"]?.string == range.startKey && params["endDate"]?.string == range.endKey)
            #expect(params["mode"]?.string == "specific")
            #expect(params["projection"] == nil)
            #expect(params["offset"] == nil)
        }
        let json = UsageExport.params(.json, range: range, at: stamp)
        #expect(json["includeContextWeight"]?.bool == true)
        #expect(json["limit"]?.int == UsageExport.sessionLimit)
        let sessions = UsageExport.params(.sessionsCSV, range: range, at: stamp)
        #expect(sessions["limit"]?.int == UsageExport.sessionLimit)
        #expect(sessions["includeContextWeight"]?.bool != true)
        let daily = UsageExport.params(.dailyCSV, range: range, at: stamp)
        #expect(daily["limit"]?.int == 1)
        #expect(daily["includeContextWeight"]?.bool != true)
    }

    @Test func buildProducesFilesAndRejectsIncompleteCache() throws {
        for format in UsageExportFormat.allCases {
            let file = try UsageExport.build(format, result: fixture(), date: stamp, calendar: utc)
            #expect(file.format == format && !file.data.isEmpty)
            #expect(file.name == UsageExport.fileName(format, date: stamp, calendar: utc))
            #expect(throws: UsageExportError.incomplete) {
                try UsageExport.build(format, result: fixture(partial: true), date: stamp, calendar: utc)
            }
        }
        let fresh = fixture().setting("cacheStatus", ["status": "fresh"])
        #expect(throws: Never.self) { try UsageExport.build(.json, result: fresh, date: stamp, calendar: utc) }
        let csv = try UsageExport.build(.sessionsCSV, result: fixture(), date: stamp, calendar: utc)
        #expect(String(decoding: csv.data, as: UTF8.self).hasPrefix("key,label,agentId"))
    }

    @MainActor @Test func modelExportSucceeds() async throws {
        var calls: [(String, JSONValue)] = []
        let model = UsageModel(methods: { ["sessions.usage"] }, now: { stamp }) { method, params in
            calls.append((method, params))
            return fixture()
        }
        let result = await model.export(.sessionsCSV)
        let file = try result.get()
        #expect(file.format == .sessionsCSV && file.name.hasPrefix("openclaw-usage-sessions-"))
        #expect(calls.count == 1 && calls[0].0 == "sessions.usage")
        #expect(calls[0].1["limit"]?.int == UsageExport.sessionLimit)
        #expect(calls[0].1["projection"] == nil)
        #expect(model.exporting == nil)
        let daily = try await model.export(.dailyCSV).get()
        #expect(String(decoding: daily.data, as: UTF8.self).contains("2026-10-15,1,2,3,4,10"))
        let json = try await model.export(.json).get()
        #expect(calls.last?.1["includeContextWeight"]?.bool == true)
        #expect(try JSONValue.decode(json.data).object?.keys.count == 4)
    }

    #if DEBUG
    @MainActor @Test func buildRunsOffTheMainThread() async throws {
        let model = UsageModel(methods: { ["sessions.usage"] }, now: { stamp }) { _, _ in fixture() }
        let probe = UsageExportProbe()
        model.exportProbe = probe
        _ = try await model.export(.json).get()
        let counts = probe.snapshot()
        #expect(counts.main == 0 && counts.worker == 1)
    }
    #endif

    @Test func leadingNewlineStillNeutralized() {
        #expect(UsageExport.csvCell("\n=1") == "\"'\n=1\"")
        #expect(UsageExport.csvCell("\r\n=1") == "\"'\r\n=1\"")
    }

    /// `new Date(ms).toISOString()` keeps the exact millisecond; a fractional `Date` lost one.
    @Test func isoTimestampsKeepExactMilliseconds() {
        #expect(UsageExport.isoTimestamp(.number(1_760_635_090_007)) == "2025-10-16T17:18:10.007Z")
        #expect(UsageExport.isoTimestamp(.number(1_763_831_890_001)) == "2025-11-22T17:18:10.001Z")
        #expect(UsageExport.isoTimestamp(.number(1_763_831_890_000)) == "2025-11-22T17:18:10.000Z")
        #expect(UsageExport.isoTimestamp(.number(-1)) == "1969-12-31T23:59:59.999Z")
        #expect(UsageExport.isoTimestamp(.string("x")) == nil)
    }

    @Test func jsNumbers() {
        #expect(UsageExport.csvCell(.number(1)) == "1")
        #expect(UsageExport.csvCell(.number(1e-5)) == "0.00001")
        #expect(UsageExport.csvCell(.number(1e-6)) == "0.000001")
        #expect(UsageExport.csvCell(.number(1e-7)) == "1e-7", "JS String(1e-7) switches to exponent below 1e-6")
        #expect(UsageExport.csvCell(.number(1.5e-7)) == "1.5e-7")
        #expect(UsageExport.csvCell(.number(123_456_789_012_345)) == "123456789012345")
        #expect(UsageExport.csvCell(.number(1e21)) == "1e+21")
        #expect(UsageExport.csvCell(.number(0.1 + 0.2)) == "0.30000000000000004")
        #expect(UsageExport.csvCell(.number(-0.5)) == "-0.5")
    }

    @Test func dailyCSVNeedsCostDaily() throws {
        var result = fixture()
        var aggregates = result["aggregates"]?.object ?? [:]
        aggregates["costDaily"] = nil
        result = result.setting("aggregates", .object(aggregates))
        #expect(throws: UsageExportError.noDaily) {
            try UsageExport.build(.dailyCSV, result: result, date: stamp, calendar: utc)
        }
        // Sessions and JSON don't need it; an empty array is a header-only file.
        #expect(throws: Never.self) { try UsageExport.build(.sessionsCSV, result: result, date: stamp, calendar: utc) }
        #expect(throws: Never.self) { try UsageExport.build(.json, result: result, date: stamp, calendar: utc) }
        aggregates["costDaily"] = []
        let empty = try UsageExport.build(.dailyCSV, result: result.setting("aggregates", .object(aggregates)), date: stamp, calendar: utc)
        #expect(String(decoding: empty.data, as: UTF8.self).components(separatedBy: "\n").count == 1)
        #expect(!UsageExportError.noDaily.message.isEmpty)
    }

    @Test func selectedUsageCompleteOverridesPartialCache() throws {
        let partial = fixture(partial: true)
        let complete = partial.setting("overview", ["selectedUsageComplete": true])
        let incomplete = partial.setting("overview", ["selectedUsageComplete": false])
        for format in UsageExportFormat.allCases {
            #expect(throws: Never.self) { try UsageExport.build(format, result: complete, date: stamp, calendar: utc) }
            #expect(throws: UsageExportError.incomplete) { try UsageExport.build(format, result: incomplete, date: stamp, calendar: utc) }
        }
        // The override only matters when the cache isn't fresh; no cacheStatus never fails.
        #expect(throws: Never.self) { try UsageExport.build(.json, result: fixture().setting("overview", ["selectedUsageComplete": false]), date: stamp, calendar: utc) }
    }

    @MainActor @Test func hostileLabelsEndToEnd() async throws {
        let rows: JSONValue = ["sessions": [
            ["key": "a", "label": "=cmd|' /C calc'!A0"],
            ["key": "b", "label": "He said \"hi\", then left"],
            ["key": "c", "label": "-2+3"],
        ], "totals": [:], "aggregates": ["costDaily": []]]
        let model = UsageModel(methods: { ["sessions.usage"] }, now: { stamp }) { _, _ in rows }
        let csv = String(decoding: try await model.export(.sessionsCSV).get().data, as: UTF8.self).components(separatedBy: "\n")
        #expect(csv[1].hasPrefix("a,'=cmd|' /C calc'!A0,"))
        #expect(csv[2].hasPrefix("b,\"He said \"\"hi\"\", then left\","))
        #expect(csv[3].hasPrefix("c,'-2+3,"))
    }

    @MainActor @Test func modelExportFailures() async {
        let unsupported = UsageModel(methods: { ["usage.cost"] }, now: { stamp }) { _, _ in fixture() }
        #expect(await unsupported.export(.json) == .failure(.unsupported))
        let unknown = UsageModel(methods: { ["sessions.usage"] }, now: { stamp }) { _, _ in
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method: sessions.usage", details: nil)
        }
        #expect(await unknown.export(.json) == .failure(.unsupported))
        let partial = UsageModel(methods: { ["sessions.usage"] }, now: { stamp }) { _, _ in fixture(partial: true) }
        for format in UsageExportFormat.allCases {
            #expect(await partial.export(format) == .failure(.incomplete))
        }
        #expect(UsageExportError.incomplete.message
            == "Usage data is incomplete. Refresh usage and try again, or narrow the date range.")
    }
}
