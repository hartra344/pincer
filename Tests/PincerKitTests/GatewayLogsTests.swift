import Foundation
import Testing
@testable import PincerKit

@Suite("Gateway log lines")
struct GatewayLogLineTests {
    @Test func upstreamExample() {
        let line = GatewayLogLine.parse(#"""
        {"0":"{\"subsystem\":\"gateway\"}","1":"listening on ws://127.0.0.1:18789","_meta":{"logLevelName":"INFO","date":"2026-09-26T18:00:00.000Z","name":"{\"subsystem\":\"gateway\"}"},"time":"2026-09-26T18:00:00.000Z"}
        """#)
        #expect(line.level == .info && line.subsystem == "gateway")
        #expect(line.message == "listening on ws://127.0.0.1:18789")
        #expect(line.timeText == "2026-09-26T18:00:00.000Z")
        #expect(line.time == Date(timeIntervalSince1970: 1_790_445_600))
    }

    @Test func fieldFallbacks() {
        let plain = GatewayLogLine.parse(#"{"level":"Warn","time":"2026-09-26T18:00:01Z","subsystem":"cron","message":"late"}"#)
        #expect(plain.level == .warn && plain.subsystem == "cron" && plain.message == "late")
        #expect(plain.time == Date(timeIntervalSince1970: 1_790_445_601))
        let metaDate = GatewayLogLine.parse(#"{"_meta":{"logLevelName":"DEBUG","date":"2026-09-26T18:00:02.500Z"},"0":"x"}"#)
        #expect(metaDate.timeText == "2026-09-26T18:00:02.500Z" && metaDate.level == .debug)
        let module = GatewayLogLine.parse(#"{"_meta":{"name":"{\"module\":\"store\"}"},"0":"saved"}"#)
        #expect(module.subsystem == "store" && module.message == "saved")
        let positionalName = GatewayLogLine.parse(#"{"0":"{\"subsystem\":\"agent\"}","1":"ran"}"#)
        #expect(positionalName.subsystem == "agent")
        #expect(GatewayLogLine.parse(#"{"level":"verbose","0":"x"}"#).level == nil)
    }

    @Test func positionalMessage() {
        let line = GatewayLogLine.parse(#"{"1":{"client":"ui"},"0":"connected","2":3,"10":"last","x":"ignored","_meta":{"logLevelName":"INFO"}}"#)
        #expect(line.message == #"connected {"client":"ui"} 3 last"#)
        #expect(GatewayLogLine.parse(#"{"_meta":{"logLevelName":"INFO"}}"#).message == "")
    }

    @Test func plainText() {
        let text = GatewayLogLine.parse("(node:1) DeprecationWarning")
        #expect(text.level == nil && text.subsystem == nil && text.message == "(node:1) DeprecationWarning")
        #expect(GatewayLogLine.parse("42").message == "42")
        #expect(GatewayLogLine.parse(#"["a"]"#).message == #"["a"]"#)
        let ansi = GatewayLogLine.parse("\u{1B}[33mwarn\u{1B}[39m \u{1B}[2m[doctor]\u{1B}[22m renew")
        #expect(ansi.message == "warn [doctor] renew" && ansi.level == nil)
    }

    @Test func stripControls() {
        #expect(GatewayLogs.stripControls("a\u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{1B}\\b") == "alinkb")
        #expect(GatewayLogs.stripControls("a\u{9B}31mb\u{0}c\u{7F}\td") == "abc\td")
        #expect(GatewayLogs.stripControls("plain") == "plain")
    }

    @Test func entryCapsDisplay() {
        let long = String(repeating: "x", count: 3_000)
        let entry = GatewayLogEntry(id: 1, line: GatewayLogLine.parse(long))
        #expect(entry.message.count == 3_000)
        #expect(entry.displayMessage == String(repeating: "x", count: 2_000) + "… (+1,000 characters)")
        #expect(GatewayLogs.copyText([entry]).count == 3_000)
    }
}

@Suite("Gateway log filtering and export")
struct GatewayLogFilterTests {
    private func entries() -> [GatewayLogEntry] {
        [
            GatewayLogEntry(id: 1, line: GatewayLogLine.parse(#"{"level":"debug","subsystem":"agent","message":"prompt ready","time":"t1"}"#)),
            GatewayLogEntry(id: 2, line: GatewayLogLine.parse(#"{"level":"error","subsystem":"cron","message":"Café failed","time":"t2"}"#)),
            GatewayLogEntry(id: 3, marker: "Now reading /tmp/b.log"),
            GatewayLogEntry(id: 4, line: GatewayLogLine.parse("plain CAFE text")),
        ]
    }

    @Test func levels() {
        var levels = GatewayLogLevels.defaults
        #expect(!levels.contains(.trace) && !levels.contains(.debug) && levels.contains(.info) && levels.contains(.fatal))
        levels.toggle(.debug)
        #expect(levels.contains(.debug))
        levels.toggle(.debug)
        #expect(levels == .defaults)
        #expect(GatewayLogLevels.all.rawValue == 0b111111)
    }

    @Test func filterKeepsMarkersAndUnleveled() {
        let filtered = GatewayLogs.filter(self.entries(), levels: .defaults, query: "")
        #expect(filtered.map(\.id) == [2, 3, 4])
        #expect(GatewayLogs.lineCount(filtered) == 2)
        #expect(GatewayLogs.filter(self.entries(), levels: .all, query: "").count == 4)
    }

    @Test func searchFoldsCaseAndDiacritics() {
        #expect(GatewayLogs.filter(self.entries(), levels: .all, query: " cafe ").map(\.id) == [2, 3, 4])
        #expect(GatewayLogs.filter(self.entries(), levels: .all, query: "AGENT").map(\.id) == [1, 3])
        #expect(GatewayLogs.filter(self.entries(), levels: .all, query: "nothing").map(\.id) == [3])
    }

    @Test func copyAndExportLeaveOutMarkers() {
        let entries = self.entries()
        #expect(GatewayLogs.copyText(entries) == "t1 DEBUG [agent] prompt ready\nt2 ERROR [cron] Café failed\nplain CAFE text")
        #expect(GatewayLogs.rawText(entries).components(separatedBy: "\n").count == 3)
        #expect(!GatewayLogs.rawText(entries).contains("Now reading"))
    }

    @Test func exportFilename() {
        let date = Date(timeIntervalSince1970: 1_790_445_600)
        let utc = TimeZone(identifier: "UTC")!
        #expect(GatewayLogs.exportFilename(gatewayName: "Home Mac (Café)", date: date, timeZone: utc)
            == "openclaw-home-mac-cafe-20260926-180000.log")
        #expect(GatewayLogs.exportFilename(gatewayName: "🦞", date: date, timeZone: utc) == "openclaw-gateway-20260926-180000.log")
    }
}

@MainActor
@Suite("Gateway logs model")
struct GatewayLogsModelTests {
    /// Answers each `logs.tail` with the next scripted result and records the params sent.
    final class Script {
        var results: [Result<JSONValue, Error>]
        var params: [JSONValue] = []
        init(_ results: [Result<JSONValue, Error>]) { self.results = results }
    }

    private func page(file: String = "/tmp/openclaw/a.log", cursor: Int, lines: [String], truncated: Bool = false,
                      reset: Bool = false, skipped: Int? = nil) -> JSONValue
    {
        var object: [String: JSONValue] = [
            "file": .string(file), "cursor": JSONValue(cursor), "size": JSONValue(cursor),
            "lines": JSONValue(lines), "truncated": .bool(truncated), "reset": .bool(reset),
        ]
        if let skipped { object["skippedBytes"] = JSONValue(skipped) }
        return .object(object)
    }

    private func model(_ script: Script, methods: Set<String>? = nil) -> GatewayLogsModel {
        GatewayLogsModel(methods: { methods }) { method, params in
            #expect(method == "logs.tail")
            script.params.append(params)
            return try script.results.removeFirst().get()
        }
    }

    private func info(_ message: String) -> String { #"{"level":"info","message":"\#(message)"}"# }

    @Test func cursorAndAppend() async {
        let script = Script([
            .success(self.page(cursor: 100, lines: [self.info("a"), self.info("b")], truncated: true)),
            .success(self.page(cursor: 140, lines: [self.info("c")])),
            .success(self.page(cursor: 140, lines: [])),
        ])
        let model = self.model(script)
        await model.poll()
        #expect(script.params[0]["cursor"] == nil && script.params[0]["limit"]?.int == 500)
        #expect(script.params[0]["maxBytes"]?.int == 250_000)
        #expect(model.showsRecentOnly && model.hasLoaded && model.cursor == 100 && model.file == "/tmp/openclaw/a.log")
        await model.poll()
        #expect(script.params[1]["cursor"]?.int == 100)
        await model.poll()
        #expect(script.params[2]["cursor"]?.int == 140)
        #expect(model.entries.map(\.message) == ["a", "b", "c"])
        #expect(model.entries.map(\.id) == [1, 2, 3])
        #expect(model.lineCount == 3 && model.count(.info) == 3)
    }

    @Test func markers() async {
        let script = Script([
            .success(self.page(cursor: 10, lines: [self.info("a")])),
            .success(self.page(cursor: 20, lines: [self.info("b")], truncated: true)),
            .success(self.page(cursor: 5, lines: [self.info("c")], reset: true)),
            .success(self.page(cursor: 900, lines: [self.info("d")], truncated: true, reset: true, skipped: 2_048)),
            .success(self.page(file: "/tmp/openclaw/b.log", cursor: 3, lines: [self.info("e")], reset: true)),
        ])
        let model = self.model(script)
        for _ in 0..<5 { await model.poll() }
        let markers = model.entries.compactMap { entry -> String? in
            if case let .marker(text) = entry.kind { return text }
            return nil
        }
        #expect(markers == [
            "Some lines were skipped (too much output at once)",
            "Log file was rotated or truncated. Reading from the start.",
            "Skipped \(Int64(2_048).formatted(.byteCount(style: .file))) of log output (Pincer fell behind)",
            "Now reading /tmp/openclaw/b.log",
        ])
        #expect(!model.showsRecentOnly && model.lineCount == 5 && model.entries.count == 9)
        #expect(model.file == "/tmp/openclaw/b.log" && model.cursor == 3)
    }

    @Test func ringBufferEvicts() async {
        let script = Script([
            .success(self.page(cursor: 1, lines: (0..<5).map { self.info("x\($0)") })),
            .success(self.page(cursor: 2, lines: [#"{"level":"error","message":"e"}"#])),
        ])
        let model = self.model(script)
        model.capacity = 4
        await model.poll()
        #expect(model.entries.map(\.message) == ["x1", "x2", "x3", "x4"])
        await model.poll()
        #expect(model.entries.map(\.message) == ["x2", "x3", "x4", "e"])
        #expect(model.entries.map(\.id) == [2, 3, 4, 5])
        #expect(model.count(.info) == 3 && model.count(.error) == 1 && model.lineCount == 4)
        #expect(model.bufferedBytes == model.entries.reduce(0) { $0 + $1.raw.utf8.count })
    }

    @Test func byteCapacityEvicts() async {
        let big = String(repeating: "y", count: 100)
        let script = Script([.success(self.page(cursor: 1, lines: [big, big, big]))])
        let model = self.model(script)
        model.byteCapacity = 250
        await model.poll()
        #expect(model.entries.count == 2 && model.bufferedBytes == 200)
    }

    @Test func clearKeepsCursor() async {
        let script = Script([
            .success(self.page(cursor: 10, lines: [self.info("a")])),
            .success(self.page(cursor: 20, lines: [self.info("b")])),
        ])
        let model = self.model(script)
        await model.poll()
        model.clear()
        #expect(model.entries.isEmpty && model.lineCount == 0 && model.bufferedBytes == 0 && model.cursor == 10)
        await model.poll()
        #expect(script.params[1]["cursor"]?.int == 10 && model.entries.map(\.message) == ["b"])
    }

    @Test func pausedRunDoesNotPoll() async {
        let script = Script([])
        let model = self.model(script)
        model.isPaused = true
        await model.run()
        #expect(script.params.isEmpty && !model.hasLoaded)
    }

    @Test func failuresAndBackoff() async {
        let script = Script([
            .failure(GatewayError.rpc(code: "UNAVAILABLE", message: "log read failed: EACCES: permission denied", details: nil)),
            .failure(GatewayError.rpc(code: "UNAVAILABLE", message: "busy", details: nil)),
            .failure(GatewayError.notConnected),
            .success(self.page(cursor: 1, lines: [])),
        ])
        let model = self.model(script)
        await model.poll()
        #expect(model.failure == .unavailable("EACCES: permission denied"))
        #expect(model.failure?.message == "Couldn't read the gateway log: EACCES: permission denied. Retrying…")
        #expect(model.nextDelay == .seconds(2))
        await model.poll()
        #expect(model.failure == .unavailable("busy") && model.nextDelay == .seconds(4))
        await model.poll()
        #expect(model.failure == .unavailable("busy") && model.nextDelay == .seconds(8))
        await model.poll()
        #expect(model.failure == nil && model.nextDelay == .seconds(2) && model.hasLoaded)
        #expect(GatewayLogsModel.delay(interval: .seconds(2), failures: 4) == .seconds(10))
        #expect(GatewayLogsModel.delay(interval: .seconds(2), failures: 20) == .seconds(10))
    }

    @Test func missingScopeStopsRun() async {
        let script = Script([
            .failure(GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.read",
                                      details: .object(["code": .string("MISSING_SCOPE")]))),
        ])
        let model = self.model(script)
        await model.run()
        #expect(model.failure == .missingScope && script.params.count == 1)
        #expect(model.failure?.message == GatewayLogsModel.missingScopeMessage)
        let generation = model.retryGeneration
        model.retry()
        #expect(model.failure == nil && model.retryGeneration == generation + 1)
        #expect(GatewayLogsModel.failure(for: GatewayError.rpc(code: "X", message: "boom", details: nil)) == .other("boom"))
    }

    @Test func unsupported() async {
        let advertised = Script([])
        let hidden = self.model(advertised, methods: ["chat.send"])
        await hidden.run()
        #expect(!hidden.supported && advertised.params.isEmpty && hidden.hasLoaded)

        let unknown = Script([.failure(GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: logs.tail", details: nil))])
        let model = self.model(unknown)
        await model.run()
        #expect(!model.supported && model.failure == nil && unknown.params.count == 1)
    }

    @Test func largePageParsesInBackground() async {
        let lines = (0..<1_200).map { self.info("l\($0)") }
        let script = Script([.success(self.page(cursor: 1, lines: lines))])
        let model = self.model(script)
        await model.poll()
        #expect(model.entries.count == 1_200 && model.entries.last?.message == "l1199")
    }

    @Test func pageDecoding() {
        #expect(GatewayLogPage(.object(["lines": JSONValue(["a"])])) == nil)
        let page = GatewayLogPage(Fixtures.json(#"{"file":"/f","cursor":5,"size":9,"lines":["a",1,"b"],"skippedBytes":3}"#))
        #expect(page?.lines == ["a", "b"] && page?.cursor == 5 && page?.size == 9 && page?.skippedBytes == 3)
    }
}

@Suite("Demo gateway log file")
struct DemoGatewayLogsTests {
    @Test func seededTail() throws {
        var logs = DemoGatewayLogs()
        let first = try logs.tail(.object([:]))
        let lines = first["lines"]?.array?.compactMap(\.string) ?? []
        #expect(lines.count > 100 && lines.count <= 500)
        #expect(first["file"]?.string?.hasPrefix("/tmp/openclaw/openclaw-") == true)
        let parsed = lines.map(GatewayLogLine.parse)
        for level in GatewayLogLevel.allCases { #expect(parsed.contains { $0.level == level }, "\(level)") }
        #expect(parsed.contains { $0.level == nil })
        #expect(parsed.contains { $0.message == "control UI served at /" && $0.subsystem == "gateway" })
        #expect(parsed.contains { $0.message.count > 3_000 })
    }

    @Test func sliceSemantics() {
        var logs = DemoGatewayLogs()
        let size = logs.size
        #expect(logs.slice(cursor: size, limit: 500, maxBytes: 250_000).lines.isEmpty)
        logs.log(.info, "gateway", "new line")
        let next = logs.slice(cursor: size, limit: 500, maxBytes: 250_000)
        #expect(next.lines.count == 1 && next.cursor == logs.size && !next.reset && !next.truncated)
        let limited = logs.slice(cursor: nil, limit: 3, maxBytes: 250_000)
        #expect(limited.lines.count == 3 && limited.truncated)
        let rotated = logs.slice(cursor: logs.size + 10, limit: 500, maxBytes: 250_000)
        #expect(rotated.reset && rotated.skippedBytes == nil)
        let behind = logs.slice(cursor: 0, limit: 500, maxBytes: 1_000)
        #expect(behind.reset && behind.truncated && (behind.skippedBytes ?? 0) > 0)
        let midLine = logs.slice(cursor: size - 3, limit: 500, maxBytes: 250_000)
        #expect(midLine.lines == [logs.lines.last!])
    }

    @Test func validation() {
        for params in [#"{"follow":true}"#, #"{"limit":0}"#, #"{"limit":5001}"#, #"{"maxBytes":1000001}"#,
                       #"{"cursor":-1}"#, #"{"cursor":"1"}"#, #"{"limit":1.5}"#]
        {
            #expect(throws: GatewayError.self) { try DemoGatewayLogs.validate(Fixtures.json(params)) }
        }
        let valid = try? DemoGatewayLogs.validate(Fixtures.json(#"{"cursor":0,"limit":5000,"maxBytes":1000000}"#))
        #expect(valid?.cursor == 0 && valid?.limit == 5_000 && valid?.maxBytes == 1_000_000)
    }

    @Test func ticksAppend() {
        let start = Date()
        var logs = DemoGatewayLogs(now: start)
        let count = logs.lines.count
        logs.tick(now: start.addingTimeInterval(0.2))
        #expect(logs.lines.count == count)
        logs.tick(now: start.addingTimeInterval(2))
        #expect((count + 1...count + 4).contains(logs.lines.count))
    }
}

// MARK: Edge cases (tester)

@Suite("Gateway log edge cases")
struct GatewayLogEdgeCaseTests {
    @Test func stripControlsUnterminatedAndCR() {
        #expect(GatewayLogs.stripControls("a\u{1B}") == "a")
        #expect(GatewayLogs.stripControls("a\u{1B}[31") == "a")
        #expect(GatewayLogs.stripControls("a\u{1B}]0;title") == "a")
        #expect(GatewayLogs.stripControls("line\r\nnext\u{1B}(B!") == "linenext!")
        #expect(GatewayLogs.stripControls("é🦞\u{1B}[1;31m→\u{1B}[0m") == "é🦞→")
    }

    @Test func rawKeptVerbatimAndSubsystemStripped() {
        let raw = "{\"level\":\"info\",\"subsystem\":\"\\u001b[2mcron\\u001b[0m\",\"message\":\"\\u001b[31mred\\u001b[0m\"}"
        let line = GatewayLogLine.parse(raw)
        #expect(line.raw == raw && line.message == "red" && line.subsystem == "cron")
    }

    @Test func metaLevelWinsOverObjectLevel() {
        let line = GatewayLogLine.parse(#"{"level":"debug","_meta":{"logLevelName":"ERROR"},"message":"m"}"#)
        #expect(line.level == .error)
        let plugin = GatewayLogLine.parse(#"{"_meta":{"name":"{\"plugin\":\"weather\"}"},"0":"ok"}"#)
        #expect(plugin.message == "ok")
    }

    @Test func invalidTimeKeepsText() {
        let line = GatewayLogLine.parse(#"{"level":"info","time":"yesterday","message":"m"}"#)
        #expect(line.timeText == "yesterday" && line.time == nil)
    }

    @Test func displayCapCountsCharactersNotBytes() {
        let emoji = String(repeating: "🦞", count: 1_500)
        let entry = GatewayLogEntry(id: 1, line: GatewayLogLine.parse(emoji))
        #expect(entry.displayMessage == emoji)
        let long = String(repeating: "é", count: 2_001)
        #expect(GatewayLogEntry(id: 2, line: GatewayLogLine.parse(long)).displayMessage.hasSuffix("… (+1 characters)"))
    }

    @Test func entryBytesAreUTF8() {
        let entry = GatewayLogEntry(id: 1, line: GatewayLogLine.parse("é🦞"))
        #expect(entry.byteCount == 6)
    }

    @Test func searchMatchesRawAndSubsystem() {
        let entry = GatewayLogEntry(id: 1, line: GatewayLogLine.parse(#"{"level":"info","subsystem":"Channels/Discord","message":"hi","runId":"run_ABC"}"#))
        #expect(GatewayLogs.filter([entry], levels: .all, query: "channels/discord").count == 1)
        #expect(GatewayLogs.filter([entry], levels: .all, query: "RUN_abc").count == 1)
        #expect(GatewayLogs.filter([entry], levels: [], query: "").isEmpty)
        let plain = GatewayLogEntry(id: 2, line: GatewayLogLine.parse("plain"))
        #expect(GatewayLogs.filter([plain], levels: [], query: "").count == 1)
        #expect(GatewayLogs.filter([plain], levels: [], query: "zzz").isEmpty)
    }

    @Test func exportIsFilteredRawLines() {
        let entries = [
            GatewayLogEntry(id: 1, line: GatewayLogLine.parse(#"{"level":"debug","message":"hidden"}"#)),
            GatewayLogEntry(id: 2, marker: "Now reading /x"),
            GatewayLogEntry(id: 3, line: GatewayLogLine.parse(#"{"level":"warn","message":"shown"}"#)),
        ]
        let visible = GatewayLogs.filter(entries, levels: .defaults, query: "")
        #expect(GatewayLogs.rawText(visible) == #"{"level":"warn","message":"shown"}"#)
        #expect(GatewayLogs.rawText([entries[1]]).isEmpty && GatewayLogs.copyText([entries[1]]).isEmpty)
    }
}

@MainActor
@Suite("Gateway logs model edge cases")
struct GatewayLogsModelEdgeCaseTests {
    final class Script {
        var results: [Result<JSONValue, Error>]
        var params: [JSONValue] = []
        var delay: Duration?
        init(_ results: [Result<JSONValue, Error>]) { self.results = results }
    }

    private func page(file: String? = "/tmp/openclaw/a.log", cursor: Int, lines: [String], truncated: Bool = false,
                      reset: Bool = false, skipped: Int? = nil) -> JSONValue
    {
        var object: [String: JSONValue] = [
            "cursor": JSONValue(cursor), "size": JSONValue(cursor), "lines": JSONValue(lines),
            "truncated": .bool(truncated), "reset": .bool(reset),
        ]
        if let file { object["file"] = .string(file) }
        if let skipped { object["skippedBytes"] = JSONValue(skipped) }
        return .object(object)
    }

    private func model(_ script: Script, methods: Set<String>? = nil) -> GatewayLogsModel {
        GatewayLogsModel(methods: { methods }) { _, params in
            script.params.append(params)
            if let delay = script.delay { try await Task.sleep(for: delay) }
            return try script.results.removeFirst().get()
        }
    }

    private func info(_ message: String) -> String { #"{"level":"info","message":"\#(message)"}"# }
    private func markers(_ model: GatewayLogsModel) -> [String] { model.entries.filter(\.isMarker).map(\.message) }

    @Test func paramsAreClosed() async {
        let script = Script([.success(self.page(cursor: 7, lines: [])), .success(self.page(cursor: 7, lines: []))])
        let model = self.model(script)
        await model.poll()
        await model.poll()
        #expect(script.params[0].object.map { Set($0.keys) } == ["limit", "maxBytes"])
        #expect(script.params[1].object.map { Set($0.keys) } == ["cursor", "limit", "maxBytes"])
    }

    @Test func singleInFlight() async {
        let script = Script([.success(self.page(cursor: 1, lines: [self.info("a")]))])
        script.delay = .milliseconds(100)
        let model = self.model(script)
        async let first: Void = model.poll()
        try? await Task.sleep(for: .milliseconds(10))
        await model.poll()
        await first
        #expect(script.params.count == 1 && model.entries.count == 1)
    }

    @Test func oversizedPageKeepsLastCapacityWithSequentialIds() async {
        let script = Script([
            .success(self.page(cursor: 1, lines: (0..<10).map { self.info("x\($0)") })),
            .success(self.page(cursor: 2, lines: [self.info("y")])),
        ])
        let model = self.model(script)
        model.capacity = 3
        await model.poll()
        #expect(model.entries.map(\.message) == ["x7", "x8", "x9"] && model.entries.map(\.id) == [1, 2, 3])
        await model.poll()
        #expect(model.entries.map(\.id) == [2, 3, 4] && model.lineCount == 3 && model.count(.info) == 3)
    }

    @Test func byteCapacityKeepsNewestEvenIfHuge() async {
        let huge = String(repeating: "z", count: 500)
        let script = Script([.success(self.page(cursor: 1, lines: ["a", huge]))])
        let model = self.model(script)
        model.byteCapacity = 100
        await model.poll()
        #expect(model.entries.map(\.raw) == [huge] && model.bufferedBytes == 500 && model.lineCount == 1)
    }

    @Test func byteCapacityCountsUTF8() async {
        let wide = String(repeating: "🦞", count: 25) // 100 bytes, 25 characters
        let script = Script([.success(self.page(cursor: 1, lines: [wide, wide, wide]))])
        let model = self.model(script)
        model.byteCapacity = 250
        await model.poll()
        #expect(model.entries.count == 2 && model.bufferedBytes == 200)
    }

    @Test func markerEvictionKeepsCounts() async {
        let script = Script([
            .success(self.page(cursor: 10, lines: [self.info("a")])),
            .success(self.page(cursor: 5, lines: [self.info("b"), self.info("c")], reset: true)),
        ])
        let model = self.model(script)
        model.capacity = 2
        await model.poll()
        await model.poll()
        #expect(model.entries.map(\.message) == ["b", "c"] && model.lineCount == 2 && model.count(.info) == 2)
        #expect(model.bufferedBytes == model.entries.reduce(0) { $0 + $1.raw.utf8.count })
    }

    @Test func firstReadMarkersAndFileNil() async {
        let script = Script([
            .success(self.page(cursor: 10, lines: [self.info("a")], truncated: true)),
            .success(self.page(file: nil, cursor: 12, lines: [self.info("b")])),
            .success(self.page(file: "/tmp/openclaw/a.log", cursor: 14, lines: [])),
        ])
        let model = self.model(script)
        await model.poll()
        #expect(self.markers(model).isEmpty && model.showsRecentOnly)
        await model.poll()
        await model.poll()
        #expect(self.markers(model).isEmpty && model.file == "/tmp/openclaw/a.log" && model.cursor == 14)
        #expect(model.showsRecentOnly, "recent-only note belongs to the first read")
    }

    @Test func resetWithZeroSkippedIsRotation() async {
        let script = Script([
            .success(self.page(cursor: 10, lines: [])),
            .success(self.page(cursor: 3, lines: [], reset: true, skipped: 0)),
        ])
        let model = self.model(script)
        await model.poll()
        await model.poll()
        #expect(self.markers(model) == ["Log file was rotated or truncated. Reading from the start."])
    }

    @Test func pauseKeepsCursorAndResumeCatchesUp() async {
        let script = Script([
            .success(self.page(cursor: 100, lines: [self.info("a")])),
            .success(self.page(cursor: 900_000, lines: [self.info("z")], truncated: true, reset: true, skipped: 500_000)),
        ])
        let model = self.model(script)
        await model.poll()
        model.isPaused = true
        await model.run()
        #expect(script.params.count == 1 && model.cursor == 100)
        model.isPaused = false
        await model.poll()
        #expect(script.params[1]["cursor"]?.int == 100)
        #expect(self.markers(model).count == 1 && self.markers(model)[0].hasPrefix("Skipped "))
        #expect(model.entries.map(\.message) == ["a", self.markers(model)[0], "z"])
    }

    @Test func errorsKeepLinesAndCursor() async {
        let script = Script([
            .success(self.page(cursor: 10, lines: [self.info("a")])),
            .failure(GatewayError.rpc(code: "UNAVAILABLE", message: "log read failed: EIO", details: nil)),
            .failure(GatewayError.rpc(code: "INTERNAL", message: "boom", details: nil)),
            .success(self.page(cursor: 20, lines: [self.info("b")])),
        ])
        let model = self.model(script)
        await model.poll()
        await model.poll()
        #expect(model.failure == .unavailable("EIO") && model.entries.count == 1 && model.cursor == 10)
        await model.poll()
        #expect(model.failure == .other("boom") && model.entries.count == 1)
        await model.poll()
        #expect(script.params[3]["cursor"]?.int == 10 && model.failure == nil && model.entries.count == 2)
    }

    @Test func notConnectedBacksOffSilently() async {
        let script = Script([.failure(GatewayError.notConnected), .failure(GatewayError.notConnected)])
        let model = self.model(script)
        await model.poll()
        await model.poll()
        #expect(model.failure == nil && model.nextDelay == .seconds(4) && model.supported)
    }

    @Test func malformedResultIsAnError() async {
        let script = Script([.success(.object(["lines": JSONValue(["a"])]))])
        let model = self.model(script)
        await model.poll()
        #expect(model.failure != nil && model.entries.isEmpty && model.cursor == nil)
    }

    @Test func errorMapping() {
        func map(_ code: String, _ message: String, _ details: JSONValue? = nil) -> GatewayLogsModel.Failure {
            GatewayLogsModel.failure(for: GatewayError.rpc(code: code, message: message, details: details))
        }
        #expect(map("MISSING_SCOPE", "nope") == .missingScope)
        #expect(map("FORBIDDEN", "requires operator.read") == .missingScope)
        #expect(map("FORBIDDEN", "x", .object(["code": .string("MISSING_SCOPE")])) == .missingScope)
        #expect(map("UNAVAILABLE", "Log read failed:  ENOENT") == .unavailable("ENOENT"))
        #expect(map("UNAVAILABLE", "disk busy") == .unavailable("disk busy"))
        #expect(map("FORBIDDEN", "operator.admin required") == .other("operator.admin required"))
        #expect(GatewayLogsModel.failure(for: GatewayError.notConnected) != .missingScope)
    }

    @Test func unknownMethodVariants() async {
        for error in [GatewayError.rpc(code: "METHOD_NOT_FOUND", message: "nope", details: nil),
                      GatewayError.rpc(code: "INVALID_REQUEST", message: "Unknown method: logs.tail", details: nil)]
        {
            let model = self.model(Script([.failure(error)]))
            await model.run()
            #expect(!model.supported && model.failure == nil)
        }
        let empty = Script([.success(self.page(cursor: 1, lines: []))])
        let unknownList = self.model(empty, methods: [])
        await unknownList.poll()
        #expect(unknownList.supported && empty.params.count == 1, "an empty method list means unknown, not unsupported")
    }

    @Test func backoffCurve() {
        let delays = (0...5).map { GatewayLogsModel.delay(interval: .seconds(2), failures: $0) }
        #expect(delays == [.seconds(2), .seconds(2), .seconds(4), .seconds(8), .seconds(10), .seconds(10)])
    }

    @Test func pageDefaults() {
        let page = GatewayLogPage(Fixtures.json(#"{"cursor":4,"lines":[]}"#))
        #expect(page?.size == 4 && page?.file == nil && page?.truncated == false && page?.reset == false)
        #expect(GatewayLogPage(Fixtures.json(#"{"cursor":-1,"lines":[]}"#)) == nil)
    }
}

@Suite("Demo gateway log cursor bytes")
struct DemoGatewayLogsByteTests {
    @Test func cursorCountsUTF8Bytes() {
        var logs = DemoGatewayLogs()
        #expect(logs.size == logs.lines.reduce(0) { $0 + $1.utf8.count + 1 })
        let before = logs.size
        logs.appendRaw("é🦞 → done")
        #expect(logs.size - before == "é🦞 → done".utf8.count + 1)
        #expect("é🦞 → done".utf8.count != "é🦞 → done".count)
        let next = logs.slice(cursor: before, limit: 500, maxBytes: 250_000)
        #expect(next.lines == ["é🦞 → done"] && next.cursor == logs.size)
        // A cursor inside the multi-byte line only returns later complete lines.
        logs.appendRaw("after")
        let mid = logs.slice(cursor: before + 2, limit: 500, maxBytes: 250_000)
        #expect(mid.lines == ["after"])
    }

    @Test func tailRespectsMaxBytes() {
        let logs = DemoGatewayLogs()
        for maxBytes in [1, 100, 5_000, logs.size - 1] {
            let slice = logs.slice(cursor: nil, limit: 5_000, maxBytes: maxBytes)
            let bytes = slice.lines.reduce(0) { $0 + $1.utf8.count + 1 }
            #expect(bytes <= maxBytes, "maxBytes \(maxBytes)")
            #expect(slice.truncated && !slice.reset && slice.cursor == logs.size, "maxBytes \(maxBytes) size \(logs.size) \(slice.truncated)")
        }
    }

    @Test func boundaryIsNotReset() {
        let logs = DemoGatewayLogs()
        let maxBytes = 10_000
        let exact = logs.slice(cursor: logs.size - maxBytes, limit: 5_000, maxBytes: maxBytes)
        #expect(!exact.reset && exact.skippedBytes == nil)
        let behind = logs.slice(cursor: logs.size - maxBytes - 1, limit: 5_000, maxBytes: maxBytes)
        #expect(behind.reset && behind.truncated && behind.skippedBytes == 1)
        let rotatedLarge = logs.slice(cursor: logs.size + 1, limit: 5_000, maxBytes: maxBytes)
        #expect(rotatedLarge.reset && rotatedLarge.truncated && rotatedLarge.skippedBytes == nil)
    }

    @Test func limitTruncatesToNewest() {
        let logs = DemoGatewayLogs()
        let slice = logs.slice(cursor: 0, limit: 2, maxBytes: 1_000_000)
        #expect(slice.lines == Array(logs.lines.suffix(2)) && slice.truncated && !slice.reset)
    }

    @Test func resultHasOnlyProtocolKeys() throws {
        var logs = DemoGatewayLogs()
        let allowed: Set<String> = ["file", "cursor", "size", "lines", "truncated", "reset", "skippedBytes"]
        let first = try logs.tail(.object([:]))
        let keys = Set(first.object?.keys ?? [:].keys)
        #expect(keys.isSubset(of: allowed) && ["file", "cursor", "size", "lines"].allSatisfy(keys.contains))
        let behind = try logs.tail(.object(["cursor": JSONValue(0), "maxBytes": JSONValue(100)]))
        #expect(Set(behind.object?.keys ?? [:].keys).isSubset(of: allowed) && (behind["skippedBytes"]?.int ?? 0) > 0)
    }

    @Test func tailCursorAdvancesOnlyOverCompleteLines() throws {
        let start = Date()
        var logs = DemoGatewayLogs(now: start)
        let first = try logs.tail(.object([:]), now: start)
        let cursor = try #require(first["cursor"]?.int)
        #expect(cursor == logs.size)
        let second = try logs.tail(.object(["cursor": JSONValue(cursor)]), now: start.addingTimeInterval(3))
        let lines = second["lines"]?.array?.compactMap(\.string) ?? []
        #expect((1...4).contains(lines.count))
        #expect(second["cursor"]?.int == cursor + lines.reduce(0) { $0 + $1.utf8.count + 1 })
    }

    @Test func rejectsNonObjectParams() {
        #expect(throws: GatewayError.self) { try DemoGatewayLogs.validate(.null) }
        #expect(throws: GatewayError.self) { try DemoGatewayLogs.validate(Fixtures.json(#"["cursor"]"#)) }
        #expect(throws: GatewayError.self) { try DemoGatewayLogs.validate(Fixtures.json(#"{"limit":true}"#)) }
    }
}
