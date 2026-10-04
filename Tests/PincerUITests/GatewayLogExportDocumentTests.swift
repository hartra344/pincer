#if DEBUG
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Gateway log export document", .timeLimit(.minutes(2)))
struct GatewayLogExportDocumentTests {
    @Test func confirmedExportPreparationFeedsExactPlatformDocument() async {
        let entries = await Task.detached {
            [GatewayLogEntry(id: 1, line: GatewayLogLine.parse("first raw line")),
             GatewayLogEntry(id: 2, marker: "not exported"),
             GatewayLogEntry(id: 3, line: GatewayLogLine.parse("last é line"))]
        }.value
        let preparation = GatewayLogExportPreparation()
        let probe = GatewayLogExportProbe(); preparation.probe = probe
        let prepared = await preparation.prepare(entries, gatewayName: "Demo", date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        let document = ExportedFile(logExport: prepared)
        #expect(document.data == Data("first raw line\nlast é line".utf8))
        #expect(document.name == "openclaw-demo-19700101-000000.log")
        #expect(probe.snapshot().mainJoins == 0 && probe.snapshot().mainEncodes == 0)
    }
}
#endif
