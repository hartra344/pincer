#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Gateway log page preparation", .timeLimit(.minutes(2)))
struct GatewayLogPagePreparationTests {
    @Test func ordinaryLegalPagePreparesActualLinesAndRowsOffMain() async throws {
        let lines = try await Task.detached {
            try (0..<64).map { index in
                let message = "Résumé \(index) " + String(repeating: "body ", count: index == 0 ? 500 : 200)
                let value: JSONValue = ["time": "2026-10-04T12:00:00.000Z", "level": "info",
                    "subsystem": "gateway/test", "message": .string(message)]
                return String(decoding: try value.encoded(), as: UTF8.self)
            }
        }.value
        #expect(lines.count <= GatewayLogsModel.limit && lines.reduce(0) { $0 + $1.utf8.count + 1 } < GatewayLogsModel.maxBytes)
        var requests: [JSONValue] = []
        let model = GatewayLogsModel(methods: { ["logs.tail"] }) { method, params in
            #expect(method == "logs.tail")
            requests.append(params)
            return ["file": "/fixture/gateway.log", "cursor": 120000, "size": 120000,
                    "lines": .array(lines.map(JSONValue.string)), "truncated": true]
        }
        let probe = GatewayLogPreparationProbe(); model.pagePreparationProbe = probe
        await model.poll() // Actual completion, not a synthetic parse helper or readiness marker.
        let counts = probe.snapshot()
        #expect(counts.mainParses == 0 && counts.mainRows == 0,
                "Actual legal logs.tail page parsing and row normalization stay off Main")
        #expect(counts.mainParses + counts.offMainParses == 64 && counts.mainRows + counts.offMainRows == 64,
                "Per-model probe sees both real preparation boundaries")
        #expect(model.entries.count == 64 && model.lineCount == 64 && model.count(.info) == 64)
        let first = try #require(model.entries.first)
        #expect(first.raw == lines[0] && first.message.hasPrefix("Résumé 0 body"))
        #expect(first.level == .info && first.subsystem == "gateway/test" && first.timeText == "2026-10-04T12:00:00.000Z")
        #expect(first.time?.timeIntervalSince1970 == 1_791_115_200)
        #expect(first.displayMessage.hasPrefix("Résumé 0 body") && first.displayMessage.contains("… (+"))
        #expect(first.displayRaw.hasPrefix("{") && first.byteCount == lines[0].utf8.count)
        #expect(first.searchText.contains("resume 0 body") && first.searchText.contains("gateway/test"))
        #expect(model.entries.map(\.id) == Array(1...64))
        #expect(model.cursor == 120000 && model.size == 120000 && model.file == "/fixture/gateway.log" && model.showsRecentOnly)
        #expect(requests[0]["limit"]?.int == 500 && requests[0]["maxBytes"]?.int == 250000 && requests[0]["cursor"] == nil)
        let entries = model.entries
        let filtered = await Task.detached { GatewayLogs.filter(entries, levels: .all, query: "resume 63") }.value
        #expect(filtered.count == 1 && filtered.first?.id == 64)
        model.clear()
        #expect(model.entries.isEmpty && model.lineCount == 0 && model.bufferedBytes == 0 && model.cursor == 120000)
    }
}
#endif
