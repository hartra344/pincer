import Foundation
@testable import PincerKit
@testable import PincerUI
import Testing

@MainActor @Suite("Premeasure source admission", .serialized)
struct PremeasureAdmissionTests {
    @Test(arguments: ["large", "foreign", "grapheme"])
    func actualDriverDoesNotPrepareFullSourcesOnMain(kind: String) async throws {
        let pieces = await Task.detached { () -> [String] in
            switch kind {
            case "foreign": return [NSString(string: String(repeating: "\u{2003}", count: 20_000) + "Visible") as String, "Second"]
            case "grapheme": return ["a" + String(repeating: "\u{301}", count: 100_000), "Second"]
            default: return [String(repeating: "A", count: 1_048_576), String(repeating: "B", count: 1_048_576)]
            }
        }.value
        if kind == "foreign" { try #require(!pieces[0].isContiguousUTF8) }
        let item = ChatItem(id: "admission-\(kind)", role: .user, blocks: pieces.map { .text($0) })
        let row = TranscriptRow.entry(.user(item))
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let driver = TranscriptPremeasureDriver()
        PremeasureAdmissionProbe.register(row.id)
        defer { PremeasureAdmissionProbe.remove(row.id) }
        let split = driver.split([0], all: [row], width: 360, renderer: renderer)
        #expect(!split.offload.isEmpty || !split.measureNow.isEmpty, "real driver handles the actual row")
        let cost = PremeasureAdmissionProbe.snapshot(row.id)
        #expect(cost.mainJoins == 0)
        #expect(cost.mainSizes == 0)
        #expect(cost.mainWarmLookups == 0)
    }

    @Test func realWorkerMeasurementAndAdoptionRemainReachable() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let driver = TranscriptPremeasureDriver()
        let row = TranscriptRow.entry(.user(ChatItem(id: "admission-control", role: .user,
            blocks: [.text("First actual paragraph"), .text("Second actual paragraph")])) )
        PremeasureAdmissionProbe.register(row.id)
        defer { PremeasureAdmissionProbe.remove(row.id) }
        let job = try #require(driver.split([0], all: [row], width: 360, renderer: renderer).offload.first)
        #expect(job.bodies.first?.source == "First actual paragraph\n\nSecond actual paragraph")
        let result = TranscriptPremeasurer.shared.measureWithin(5, jobs: [job], env: renderer.textEnvironment, epoch: driver.epoch)
        #expect(result.count == 1)
        #expect(!driver.adopt(result, width: 360, epoch: driver.epoch.current).isEmpty)
        #expect(PremeasureAdmissionProbe.snapshot(row.id).offMainMeasurements > 0)
        driver.cancelAll()
        #expect(driver.adopt(result, width: 360, epoch: driver.epoch.current).isEmpty, "stale real result remains rejected")
    }
}
