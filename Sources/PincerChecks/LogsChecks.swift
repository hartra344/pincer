import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

/// Gateway Logs polling against a scripted `logs.tail`: cursor echo, markers, ring buffer, errors.
@MainActor
func checkGatewayLogsModel() async {
    print("Gateway logs")
    func page(_ file: String = "/tmp/openclaw/a.log", cursor: Int, lines: [String], truncated: Bool = false, reset: Bool = false,
              skipped: Int? = nil) -> JSONValue
    {
        var object: [String: JSONValue] = ["file": .string(file), "cursor": JSONValue(cursor), "size": JSONValue(cursor),
                                           "lines": JSONValue(lines), "truncated": .bool(truncated), "reset": .bool(reset)]
        if let skipped { object["skippedBytes"] = JSONValue(skipped) }
        return .object(object)
    }
    let boot = #"{"0":"{\"subsystem\":\"gateway\"}","1":"listening on ws://127.0.0.1:18789","_meta":{"logLevelName":"INFO","date":"2026-09-26T18:00:00.000Z","name":"{\"subsystem\":\"gateway\"}"},"time":"2026-09-26T18:00:00.000Z"}"#
    let parsed = GatewayLogLine.parse(boot)
    check(parsed.level == .info && parsed.subsystem == "gateway" && parsed.message == "listening on ws://127.0.0.1:18789",
          "tslog line parses like the Control UI")
    check(GatewayLogLine.parse("\u{1B}[31mplain\u{1B}[0m text").message == "plain text", "plain text line, ANSI stripped")

    var sent: [JSONValue] = []
    var results: [Result<JSONValue, Error>] = [
        .success(page(cursor: 50, lines: [boot, "plain", #"{"level":"debug","message":"d"}"#], truncated: true)),
        .success(page(cursor: 80, lines: [#"{"level":"error","message":"e"}"#])),
        .success(page(cursor: 10, lines: [], reset: true)),
        .success(page("/tmp/openclaw/b.log", cursor: 5, lines: ["x"], reset: true)),
        .failure(GatewayError.rpc(code: "UNAVAILABLE", message: "log read failed: EACCES", details: nil)),
        .failure(GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.read",
                                  details: .object(["code": .string("MISSING_SCOPE")]))),
    ]
    let logs = GatewayLogsModel { _, params in
        sent.append(params)
        return try results.removeFirst().get()
    }
    await logs.poll()
    check(sent.first?["cursor"] == nil && sent.first?["limit"]?.int == 500 && sent.first?["maxBytes"]?.int == 250_000,
          "first logs.tail omits cursor, asks for 500 lines / 250 KB")
    check(logs.entries.count == 3 && logs.showsRecentOnly && logs.cursor == 50, "first page buffered, recent-only note")
    await logs.poll()
    check(sent.last?["cursor"]?.int == 50 && logs.lineCount == 4 && logs.count(.error) == 1, "next poll echoes the cursor")
    await logs.poll()
    await logs.poll()
    check(logs.entries.filter(\.isMarker).map(\.message)
        == ["Log file was rotated or truncated. Reading from the start.", "Now reading /tmp/openclaw/b.log"]
        && logs.lineCount == 5, "reset and file change add one marker each, buffer kept")
    check(GatewayLogs.copyText(logs.entries).split(separator: "\n").count == 5
          && !GatewayLogs.rawText(logs.entries).contains("Now reading"), "copy/export leave markers out")
    check(GatewayLogs.filter(logs.entries, levels: .defaults, query: "").map(\.message).contains("plain")
          && !GatewayLogs.filter(logs.entries, levels: .defaults, query: "").contains { $0.level == .debug },
          "default levels hide debug, keep unleveled lines")
    await logs.poll()
    check(logs.failure == .unavailable("EACCES") && logs.nextDelay == .seconds(2), "log read failure keeps polling")
    await logs.run()
    check(logs.failure == .missingScope && results.isEmpty, "missing operator.read stops polling")
    logs.capacity = 2
    logs.retry()
    check(logs.failure == nil, "Try Again clears the error")
    check(GatewayLogs.exportFilename(gatewayName: "Home Mac", date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        == "openclaw-home-mac-19700101-000000.log", "export filename")
    let unknown = GatewayLogsModel(methods: { ["chat.send"] }) { _, _ in .null }
    await unknown.run()
    check(!unknown.supported, "gateway without logs.tail is unsupported")

    var pausedSent: [JSONValue] = []
    var pausedResults: [JSONValue] = [
        page(cursor: 40, lines: ["a", "é🦞", "c"]),
        page(cursor: 900_000, lines: ["d"], truncated: true, reset: true, skipped: 600_000),
    ]
    let paused = GatewayLogsModel { _, params in
        pausedSent.append(params)
        return pausedResults.removeFirst()
    }
    paused.byteCapacity = 7
    await paused.poll()
    check(paused.entries.map(\.raw) == ["é🦞", "c"] && paused.bufferedBytes == 7, "ring buffer evicts by UTF-8 bytes")
    paused.isPaused = true
    await paused.run()
    check(pausedSent.count == 1 && paused.cursor == 40, "paused: no polling, cursor kept")
    paused.isPaused = false
    paused.byteCapacity = GatewayLogsModel.defaultByteCapacity
    await paused.poll()
    check(pausedSent.last?["cursor"]?.int == 40 && pausedSent.last?.object.map { Set($0.keys) } == ["cursor", "limit", "maxBytes"]
          && paused.entries.contains { $0.isMarker && $0.message.hasPrefix("Skipped ") }, "resume catches up from the cursor")
}

/// Gateway Logs against the mock's live log file and its [mock:*-logs] triggers.
@MainActor
func checkGatewayLogsLive(_ gateway: GatewayStore) async {
    check(gateway.hello?.methods.contains("logs.tail") == true, "hello advertises logs.tail")
    let logs = gateway.gatewayLogs
    await logs.poll()
    check(logs.supported && logs.failure == nil && logs.lineCount > 100 && logs.file?.hasPrefix("/tmp/openclaw/openclaw-") == true,
          "logs.tail first page (\(logs.lineCount))")
    check(GatewayLogLevel.allCases.filter { logs.count($0) > 0 }.count >= 4, "mock log mixes levels")
    let firstFile = logs.file
    let lastId = logs.entries.last?.id ?? 0
    // The mock appends log lines on a fixed timer: poll until some arrive.
    let logsDeadline = Date().addingTimeInterval(30)
    var logsGrew = false
    while !logsGrew, Date() < logsDeadline {
        try? await Task.sleep(for: .milliseconds(300))
        await logs.poll()
        logsGrew = logs.entries.contains { $0.id > lastId && !$0.isMarker }
    }
    check(logs.entries.contains { $0.id > lastId && !$0.isMarker } && logs.file == firstFile, "logs.tail cursor poll gets new lines")
    let logChat = gateway.chat(for: "agent:main:main")
    func trigger(_ text: String) async { _ = await logChat.send(text) }
    func markers() -> [String] { logs.entries.filter(\.isMarker).map(\.message) }
    await trigger("rotate the log [mock:rotate-logs]")
    await logs.poll()
    check(logs.file != firstFile && markers().last == "Now reading \(logs.file ?? "")", "rotation adds a Now reading marker")
    await trigger("flood the log [mock:log-burst]")
    await logs.poll()
    check(markers().last?.hasPrefix("Skipped ") == true && markers().last?.hasSuffix("(Pincer fell behind)") == true
          && logs.entries.count <= GatewayLogsModel.defaultCapacity, "burst fast-forwards with a skipped marker (\(markers().last ?? "-"))")
    await trigger("truncate the log [mock:truncate-logs]")
    await logs.poll()
    check(markers().last == "Log file was rotated or truncated. Reading from the start.", "truncation adds a reset marker")
    await trigger("break the log [mock:logs-unavailable]")
    await logs.poll()
    check(logs.failure?.isUnavailable == true && logs.failure?.message.hasPrefix("Couldn't read the Gateway log: EACCES") == true,
          "log read failure is reported")
    await logs.poll()
    await logs.poll()
    check(logs.failure == nil, "log reads recover")
    // The trigger messages start agent runs; let them finish so a later restart isn't deferred.
    var idle = false
    for _ in 0..<3 {
        idle = await waitFor("log trigger replies", timeout: 30) { !logChat.isRunning }
        // Debounce: a reply can re-start a run just after isRunning clears.
        try? await Task.sleep(for: .milliseconds(500))
        if idle && !logChat.isRunning { break }
    }
    check(idle && !logChat.isRunning, "log trigger replies finish")
}
