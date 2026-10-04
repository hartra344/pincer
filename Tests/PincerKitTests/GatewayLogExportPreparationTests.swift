#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Gateway log export preparation", .timeLimit(.minutes(2)))
struct GatewayLogExportPreparationTests {
    @Test func lawfulRetainedPagesExportExactBytesWithoutMainPreparation() async {
        let fixture = await Task.detached {
            // Each page's 32 raw lines is below logs.tail's existing 250,000-byte bound.
            let raw = String(repeating: "é", count: 2000)
            var entries = (0..<256).map { GatewayLogEntry(id: $0, line: GatewayLogLine.parse("\($0):\(raw)")) }
            entries.insert(GatewayLogEntry(id: 1000, marker: "Rotation marker"), at: 32)
            let expected = Data(entries.filter { !$0.isMarker }.map(\.raw).joined(separator: "\n").utf8)
            return (entries, expected)
        }.value
        #expect(fixture.1.count < GatewayLogsModel.defaultByteCapacity)
        let preparation = GatewayLogExportPreparation()
        let probe = GatewayLogExportProbe(); preparation.probe = probe
        let date = Date(timeIntervalSince1970: 0), zone = TimeZone(secondsFromGMT: 0)!
        let output = await preparation.prepare(fixture.0, gatewayName: "Fixture Gateway", date: date, timeZone: zone)
        #expect(output.data == fixture.1)
        #expect(output.name == "openclaw-fixture-gateway-19700101-000000.log")
        let counts = probe.snapshot()
        #expect(counts.mainJoins == 0 && counts.mainEncodes == 0)
        #expect(counts.mainJoins + counts.workerJoins == 1 && counts.mainEncodes + counts.workerEncodes == 1)
    }
}
#endif
