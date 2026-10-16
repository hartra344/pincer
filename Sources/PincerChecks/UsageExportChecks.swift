import Foundation
@testable import PincerKit

private let exportUTC = UsageDates.calendar(TimeZone(identifier: "UTC")!)
private let exportStamp = Date(timeIntervalSince1970: 1_792_171_090.795) // 2026-10-16T17:18:10.795Z

private func exportFixture(cacheStatus: String? = nil) -> JSONValue {
    var result = json("""
    {"updatedAt": 1792171090795, "startDate": "2026-10-10", "endDate": "2026-10-16",
     "sessions": [
       {"key": "agent:main:main", "label": "Main, \\"quoted\\"", "agentId": "main", "channel": "webchat",
        "modelProvider": "anthropic", "model": "claude-opus", "updatedAt": 1792171090795,
        "contextWeight": {"total": 12},
        "usage": {"durationMs": 5000, "input": 100, "output": 50, "cacheRead": 10, "cacheWrite": 5,
                  "totalTokens": 165, "totalCost": 0.00001,
                  "messageCounts": {"total": 4, "errors": 1, "toolCalls": 2}}},
       {"key": "=SUM(1)", "providerOverride": "openai", "modelOverride": "gpt-x",
        "usage": {"input": 1, "totalTokens": 3, "totalCost": 12, "usageReport": {"state": "unavailable"},
                  "messageCounts": {"total": 1, "errors": 0, "toolCalls": 0}}}],
     "totals": {"totalTokens": 168},
     "aggregates": {"sessionCount": 2, "costDaily": [
       {"date": "2026-10-15", "input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4, "totalTokens": 10,
        "inputCost": 0.5, "outputCost": 0.25, "cacheReadCost": 0.00001, "cacheWriteCost": 0, "totalCost": 0.75001},
       {"date": "2026-10-16", "input": 9, "totalTokens": 9, "usageReport": {"state": "unavailable"}}]}}
    """)
    if let cacheStatus, var object = result.object {
        object["cacheStatus"] = ["status": .string(cacheStatus), "cachedFiles": 1, "pendingFiles": 2, "staleFiles": 0]
        result = .object(object)
    }
    return result
}

/// Counts records of an RFC 4180-ish CSV (quoted cells may hold newlines).
private func csvRecords(_ text: String) -> [[String]] {
    var records: [[String]] = [], row: [String] = [], cell = "", quoted = false
    let chars = Array(text.unicodeScalars)
    var index = 0
    while index < chars.count {
        let c = chars[index]
        if quoted {
            if c == "\"" {
                if index + 1 < chars.count, chars[index + 1] == "\"" { cell.unicodeScalars.append(c); index += 1 } else { quoted = false }
            } else { cell.unicodeScalars.append(c) }
        } else if c == "\"" { quoted = true }
        else if c == "," { row.append(cell); cell = "" }
        else if c == "\n" { row.append(cell); records.append(row); row = []; cell = "" }
        else { cell.unicodeScalars.append(c) }
        index += 1
    }
    row.append(cell); records.append(row)
    return records
}

@MainActor func runUsageExportChecks() async {
    let sessionsHeader = "key,label,agentId,channel,provider,model,updatedAt,durationMs,messages,errors,toolCalls,"
        + "inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens,totalTokens,totalCost"
    let fixture = exportFixture()
    let lines = UsageExport.sessionsCSV(fixture["sessions"]?.array ?? []).components(separatedBy: "\n")
    check(lines.first == sessionsHeader, "sessions CSV header and column order")
    check(lines.count == 3, "sessions CSV has a row per session and no trailing newline")
    check(lines[1] == "agent:main:main,\"Main, \"\"quoted\"\"\",main,webchat,anthropic,claude-opus,2026-10-16T17:18:10.795Z,"
          + "5000,4,1,2,100,50,10,5,165,0.00001", "sessions CSV row: quoting, ISO millis, integral numbers, plain small cost")
    check(lines[2] == "'=SUM(1),,,,openai,gpt-x,,,1,0,0,,,,,,",
          "formula key neutralized, provider/model overrides, unavailable usage blanks numeric cells")
    let daily = UsageExport.dailyCSV(fixture["aggregates"]?["costDaily"]?.array ?? []).components(separatedBy: "\n")
    check(daily.first == "date,inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens,totalTokens,inputCost,outputCost,"
          + "cacheReadCost,cacheWriteCost,totalCost", "daily CSV header")
    check(daily.count == 3 && daily[1] == "2026-10-15,1,2,3,4,10,0.5,0.25,0.00001,0,0.75001" && daily[2] == "2026-10-16,,,,,,,,,,",
          "daily CSV rows from costDaily, unavailable day blank")

    check(UsageExport.csvCell("  =1") == "'  =1" && UsageExport.csvCell("\t+1") == "'\t+1" && UsageExport.csvCell("-1") == "'-1"
          && UsageExport.csvCell("@a") == "'@a" && UsageExport.csvCell("＝a") == "'＝a" && UsageExport.csvCell("＋a") == "'＋a"
          && UsageExport.csvCell("－a") == "'－a" && UsageExport.csvCell("＠a") == "'＠a", "string formula prefixes neutralized")
    check(UsageExport.csvCell(.number(-1)) == "-1" && UsageExport.csvCell(.number(5.0)) == "5"
          && UsageExport.csvCell(.number(0.00001)) == "0.00001" && UsageExport.csvCell(.number(1_000_000)) == "1000000",
          "numbers aren't neutralized, integral without .0, no exponent")
    check(UsageExport.csvCell("a,b") == "\"a,b\"" && UsageExport.csvCell("a\nb") == "\"a\nb\""
          && UsageExport.csvCell("a\"b") == "\"a\"\"b\"" && UsageExport.csvCell(nil) == "" && UsageExport.csvCell(.null) == "",
          "comma, newline and quote cells quoted; missing blank")

    let parsed = try? JSONValue.decode(UsageExport.json(fixture))
    check(Set(parsed?.object?.keys.map { $0 } ?? []) == ["sessions", "totals", "aggregates", "daily"], "JSON has exactly sessions/totals/aggregates/daily")
    check(parsed?["daily"] == fixture["aggregates"]?["costDaily"] && parsed?["sessions"] == fixture["sessions"]
          && parsed?["sessions"]?[0]?["contextWeight"]?["total"]?.int == 12, "JSON daily = costDaily; unknown fields untouched")
    let bare = try? JSONValue.decode(UsageExport.json(json(#"{"sessions": [], "totals": {}, "aggregates": {}}"#)))
    check(bare?["daily"] == [], "JSON daily is [] without costDaily")

    check(UsageExport.fileName(.sessionsCSV, date: exportStamp, calendar: exportUTC) == "openclaw-usage-sessions-2026-10-16.csv"
          && UsageExport.fileName(.dailyCSV, date: exportStamp, calendar: exportUTC) == "openclaw-usage-daily-2026-10-16.csv"
          && UsageExport.fileName(.json, date: exportStamp, calendar: exportUTC) == "openclaw-usage-2026-10-16.json", "export file names")

    check(UsageExport.csvCell(.number(1)) == "1" && UsageExport.csvCell(.number(1e-5)) == "0.00001"
          && UsageExport.csvCell(.number(1e-7)) == "1e-7" && UsageExport.csvCell(.number(123_456_789_012_345)) == "123456789012345",
          "JS numbers: 1, 1e-5, 1e-7 (exponent like String(n)), a large token count")

    var noDaily = exportFixture().object ?? [:]
    noDaily["aggregates"] = ["sessionCount": 0]
    var noDailyError: UsageExportError?
    do { _ = try UsageExport.build(.dailyCSV, result: .object(noDaily), date: exportStamp, calendar: exportUTC) } catch { noDailyError = error }
    check(noDailyError == .noDaily, "daily CSV without costDaily fails with .noDaily")
    var complete = exportFixture(cacheStatus: "partial").object ?? [:]
    complete["overview"] = ["selectedUsageComplete": true]
    check((try? UsageExport.build(.sessionsCSV, result: .object(complete), date: exportStamp, calendar: exportUTC)) != nil,
          "selectedUsageComplete overrides a partial cache")

    let range = UsageDateRange.last(7, now: exportStamp, calendar: exportUTC)
    let allParams = UsageExportFormat.allCases.map { UsageExport.params($0, range: range, at: exportStamp) }
    check(allParams.allSatisfy { $0["agentScope"]?.string == "all" && $0["groupBy"]?.string == "instance" && $0["projection"] == nil
          && $0["startDate"]?.string == range.startKey }, "every export asks for all agents grouped by instance, no projection")
    check(UsageExport.params(.json, range: range, at: exportStamp)["includeContextWeight"]?.bool == true
          && UsageExport.params(.json, range: range, at: exportStamp)["limit"]?.int == UsageExport.sessionLimit
          && UsageExport.params(.sessionsCSV, range: range, at: exportStamp)["limit"]?.int == UsageExport.sessionLimit
          && UsageExport.params(.sessionsCSV, range: range, at: exportStamp)["includeContextWeight"]?.bool != true
          && UsageExport.params(.dailyCSV, range: range, at: exportStamp)["limit"]?.int == 1, "limit and includeContextWeight per format")

    for format in UsageExportFormat.allCases {
        check((try? UsageExport.build(format, result: exportFixture(cacheStatus: "fresh"), date: exportStamp, calendar: exportUTC)) != nil,
              "\(format.rawValue) builds with a fresh cache")
        var thrown: UsageExportError?
        do { _ = try UsageExport.build(format, result: exportFixture(cacheStatus: "partial"), date: exportStamp, calendar: exportUTC) }
        catch { thrown = error }
        check(thrown == .incomplete, "\(format.rawValue) fails with .incomplete for a partial cache")
    }

    var requests: [(String, JSONValue)] = []
    let model = UsageModel(methods: { ["sessions.usage"] }, now: { exportStamp }) { method, params in
        requests.append((method, params))
        return exportFixture()
    }
    for format in UsageExportFormat.allCases {
        let result = await model.export(format)
        check((try? result.get())?.format == format, "model exports \(format.rawValue)")
    }
    check(requests.count == 3 && requests.allSatisfy { $0.0 == "sessions.usage" }, "one sessions.usage request per export")
    check(model.exporting == nil, "exporting resets after an export")
    let hostile: JSONValue = ["sessions": [["key": "a", "label": "=cmd"], ["key": "b", "label": "say \"hi\", ok"]],
                              "totals": [:], "aggregates": ["costDaily": []]]
    let hostileModel = UsageModel(methods: { ["sessions.usage"] }, now: { exportStamp }) { _, _ in hostile }
    let hostileCSV = String(decoding: (try? await hostileModel.export(.sessionsCSV).get().data) ?? Data(), as: UTF8.self)
    check(hostileCSV.contains("\na,'=cmd,") && hostileCSV.contains("\nb,\"say \"\"hi\"\", ok\","),
          "model export escapes a formula label and a quote-and-comma label")
    #if DEBUG
    let probe = UsageExportProbe()
    model.exportProbe = probe
    _ = await model.export(.sessionsCSV)
    check(probe.snapshot().main == 0 && probe.snapshot().worker == 1, "export build runs off the main thread")
    #endif
    check(UsageExport.csvCell("\n=1") == "\"'\n=1\"", "leading newline doesn't hide a formula")
    let unsupported = UsageModel(methods: { ["usage.cost"] }, now: { exportStamp }) { _, _ in exportFixture() }
    let unsupportedResult = await unsupported.export(.json)
    check(unsupportedResult == .failure(.unsupported), "model: unsupported when sessions.usage isn't advertised")
    let partial = UsageModel(methods: { ["sessions.usage"] }, now: { exportStamp }) { _, _ in exportFixture(cacheStatus: "partial") }
    let partialResult = await partial.export(.sessionsCSV)
    check(partialResult == .failure(.incomplete), "model: partial cache is incomplete")
}

/// The built-in Demo Gateway: all three exports for the week, and the partial 90 days.
@MainActor func runDemoUsageExportChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("usage export Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "Demo usage export connection is ready")
    guard connected else { return }
    await checkUsageExport(gateway, label: "demo", expectsPartialQuarter: true)
}

/// The mock Gateway: the same three exports.
@MainActor func runLiveUsageExportChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Usage export", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    defer { gateway.stop() }
    let connected = await waitFor("usage export live connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "connected to the mock for usage export")
    guard connected else { return }
    await checkUsageExport(gateway, label: "live", expectsPartialQuarter: true)
}

@MainActor private func checkUsageExport(_ gateway: GatewayStore, label: String, expectsPartialQuarter: Bool) async {
    let usage = gateway.usage
    await usage.setPreset(.week)
    let plain = try? await gateway.connection.request("sessions.usage", UsageRequests.sessions(usage.range))
    let expectedCount = plain?["aggregates"]?["sessionCount"]?.int ?? -1
    let expectedDays = plain?["aggregates"]?["costDaily"]?.array?.compactMap { $0["date"]?.string } ?? []
    check(expectedCount > 0 && !expectedDays.isEmpty, "\(label): plain sessions.usage has sessions and cost days (\(expectedCount), \(expectedDays.count))")

    #if DEBUG
    let probe = UsageExportProbe()
    usage.exportProbe = probe
    defer { usage.exportProbe = nil }
    #endif
    let sessions = try? await usage.export(.sessionsCSV).get()
    check(sessions?.name.hasPrefix("openclaw-usage-sessions-") == true && sessions?.name.hasSuffix(".csv") == true, "\(label): sessions CSV file name")
    let rows = csvRecords(String(decoding: sessions?.data ?? Data(), as: UTF8.self))
    check(rows.first?.count == 17 && rows.first?.first == "key" && rows.last?.count == 17, "\(label): sessions CSV header and shape")
    check(rows.count - 1 == expectedCount, "\(label): sessions CSV has \(expectedCount) rows (got \(rows.count - 1))")
    check(rows.dropFirst().allSatisfy { !($0.first ?? "").isEmpty && (Int($0[15]) ?? 0) >= 0 }, "\(label): sessions CSV rows have keys and token totals")

    let dailyFile = try? await usage.export(.dailyCSV).get()
    let dailyRows = csvRecords(String(decoding: dailyFile?.data ?? Data(), as: UTF8.self))
    check(dailyFile?.name.hasPrefix("openclaw-usage-daily-") == true && dailyRows.dropFirst().map(\.[0]) == expectedDays,
          "\(label): daily CSV days match costDaily")

    let jsonFile = try? await usage.export(.json).get()
    let parsed = jsonFile.flatMap { try? JSONValue.decode($0.data) }
    check(jsonFile?.name.hasPrefix("openclaw-usage-") == true && jsonFile?.name.hasSuffix(".json") == true
          && Set(parsed?.object?.keys.map { $0 } ?? []) == ["sessions", "totals", "aggregates", "daily"]
          && parsed?["sessions"]?.array?.count == expectedCount && parsed?["daily"]?.array?.count == expectedDays.count,
          "\(label): JSON parses with sessions, totals, aggregates and daily")
    check(usage.exporting == nil, "\(label): exporting is reset")
    let numeric = rows.dropFirst().flatMap { Array($0[7...16]) }.filter { !$0.isEmpty }
    check(!numeric.isEmpty && numeric.allSatisfy { $0.range(of: #"^-?\d+(\.\d+)?(e[-+]\d+)?$"#, options: .regularExpression) != nil },
          "\(label): numeric cells are plain JS numbers (no .0)")
    check(rows.dropFirst().allSatisfy { !$0[0].hasPrefix("=") && !$0[1].hasPrefix("=") }, "\(label): no raw formula cells")
    #if DEBUG
    let counts = probe.snapshot()
    check(counts.main == 0 && counts.worker == 3, "\(label): the three export builds ran on a worker thread only (\(counts))")
    #endif

    if expectsPartialQuarter {
        await usage.setPreset(.quarter)
        let result = await usage.export(.sessionsCSV)
        check(result == .failure(.incomplete), "\(label): the 90-day export fails as incomplete (\(result))")
        await usage.setPreset(.week)
    }
}
