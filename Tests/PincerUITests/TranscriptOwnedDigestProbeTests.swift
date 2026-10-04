import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

#if DEBUG
@MainActor @Suite(.timeLimit(.minutes(2)))
struct TranscriptOwnedDigestProbeTests {
    @Test func scopedRecorderCountsActualKeyConstruction() {
        let recorder = TranscriptSourceDigestRecorder()
        TranscriptSourceDigestProbe.$recorder.withValue(recorder) {
            let key = TranscriptText.Key(source: "Positive actual digest key", tone: .primary, dark: false)
            #expect(key.source == "Positive actual digest key")
            #expect(recorder.count == 1)
        }
        _ = TranscriptText.Key(source: "Outside diagnostic scope", tone: .primary, dark: false)
        #expect(recorder.count == 1, "nil-default scope does not collect other operations")
    }

    /// Explicit diagnostic interleaving, not a claim about the failing CI worker's identity.
    @Test func unrelatedDetachedKeyChangesGlobalCountWithoutExtraOwnedSplitWork() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        var item = ChatItem(id: "owned-digest-source", role: .user,
                            blocks: [.text(String(repeating: "owned source body ", count: 800))], timestamp: .now)
        item.transcriptId = item.id
        let rows: [TranscriptRow] = [.entry(.user(item))]
        let driver = TranscriptPremeasureDriver()
        driver.currentRow = { id in rows.first { $0.id == id } }
        let recorder = TranscriptSourceDigestRecorder()
        await TranscriptSourceDigestProbe.$recorder.withValue(recorder) {
            let first = driver.split([0], all: rows, width: 700, renderer: renderer)
            let ownedAfterFirst = recorder.count
            let globalAfterFirst = TranscriptText.sourceDigestBuildCount
            // A detached task intentionally does not inherit the caller's task-local recorder.
            let actualSource = await Task.detached {
                TranscriptText.Key(source: "Known unrelated detached digest", tone: .primary, dark: false).source
            }.value
            #expect(actualSource == "Known unrelated detached digest")
            let second = driver.split([0], all: rows, width: 700, renderer: renderer)
            #expect(first.offload.count == 1 && second.offload.count == 1)
            #expect(renderer.premeasureBodyBuildCount == 0,
                    "actual scroll planning does not prepare text before worker admission")
            #expect(recorder.count == ownedAfterFirst,
                    "repeated actual split performs zero additional owned digest builds")
            #expect(TranscriptText.sourceDigestBuildCount > globalAfterFirst,
                    "global count includes a known unrelated actual key despite zero extra owned builds")
        }
    }
}
#endif
