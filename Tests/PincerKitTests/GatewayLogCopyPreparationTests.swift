#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct GatewayLogCopyPreparationTests {
    @Test(arguments: [GatewayLogCopyPreparation.Style.formatted, .raw])
    func actualButtonPreparationPreservesExactTextOffMain(style: GatewayLogCopyPreparation.Style) async {
        let fixture = await Task.detached {
            let raw = String(repeating: "é", count: 2000)
            var entries = (0..<256).map { GatewayLogEntry(id: $0, line: GatewayLogLine.parse("line \($0):" + raw)) }
            entries.insert(GatewayLogEntry(id: 1000, marker: "not copied"), at: 5)
            return (entries, entries.filter { !$0.isMarker }.map(\.raw).joined(separator: "\n"))
        }.value
        #expect(fixture.1.utf8.count < GatewayLogsModel.defaultByteCapacity)
        let helper = GatewayLogCopyPreparation(), probe = GatewayLogCopyProbe()
        helper.probe = probe
        let text = await helper.prepare(fixture.0, style: style)
        #expect(text == fixture.1 && !text.contains("not copied"))
        #expect(probe.snapshot().main == 0 && probe.snapshot().worker == 1)
    }
    @Test func formattedFieldsAndRawNewlinesRemainExact() async {
        let entries = await Task.detached {
            [GatewayLogEntry(id: 1, line: GatewayLogLine.parse("{\"time\":\"t1\",\"level\":\"info\",\"subsystem\":\"agent\",\"message\":\"Café ready\"}")),
             GatewayLogEntry(id: 2, marker: "not copied"), GatewayLogEntry(id: 3, line: GatewayLogLine.parse("last raw"))]
        }.value
        let helper = GatewayLogCopyPreparation()
        #expect(await helper.prepare(entries, style: .formatted) == "t1 INFO [agent] Café ready\nlast raw")
        #expect(await helper.prepare(entries, style: .raw) == entries[0].raw + "\nlast raw")
    }
}
#endif
