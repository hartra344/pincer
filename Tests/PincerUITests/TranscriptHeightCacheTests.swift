import CoreGraphics
import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// #934: a resident chat keeps its measured row heights across chat switches.
@MainActor
@Suite("Transcript height cache")
struct TranscriptHeightCacheTests {
    typealias Fake = TranscriptListControllerTests

    @MainActor private struct Rig {
        let controller: TranscriptListController
        let gateway: GatewayStore
        let a: TranscriptContext
        let b: TranscriptContext

        func switchTo(_ context: TranscriptContext, rows: [TranscriptRow]) {
            let changed = self.controller.beginUpdate(context: context, rowCount: rows.count)
            _ = self.controller.accept(rows, contextChanged: changed)
        }
    }

    private func rig(_ scratch: ScratchDefaults) -> Rig {
        let (controller, _, a) = Fake().make(scratch)
        a.chat?.hasLoaded = true
        let key = "agent:list:other"
        let chat = a.gateway.chat(for: key)
        chat.hasLoaded = true
        let b = TranscriptContext(gateway: a.gateway, disclosure: TranscriptDisclosure(), agent: a.agent, sessionKey: key,
                                  previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        return Rig(controller: controller, gateway: a.gateway, a: a, b: b)
    }

    /// Measures every row at width 400 for the open chat.
    private func measureAll(_ controller: TranscriptListController) {
        _ = controller.measure(Array(controller.rows.indices), width: 400, deadline: nil)
    }

    @Test func revisitRestoresMeasuredHeightsWithoutRemeasuring() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let rig = self.rig(scratch)
        let controller = rig.controller
        let rows = Fake.rows(0..<6)
        _ = controller.accept(rows, contextChanged: false)
        self.measureAll(controller)
        let before = controller.heights
        #expect(before.count == 6)

        rig.switchTo(rig.b, rows: Fake.rows(10..<14))
        #expect(controller.heights.isEmpty)
        rig.switchTo(rig.a, rows: rows)
        #expect(controller.heights == before)
        #expect(controller.heightCacheStats.restored == 6 && controller.heightCacheStats.rejected == 0)

        let measured = controller.prefetchStats.rowsMeasured, builds = controller.renderer.layoutBuildCount
        let result = controller.measure(Array(rows.indices), width: 400, deadline: nil)
        #expect(result.changed.isEmpty)
        #expect(controller.prefetchStats.rowsMeasured == measured)
        #expect(controller.renderer.layoutBuildCount == builds)
    }

    @Test func editedRowIsRejectedAndRemeasured() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let rig = self.rig(scratch)
        let controller = rig.controller
        _ = controller.accept(Fake.rows(0..<4), contextChanged: false)
        self.measureAll(controller)
        rig.switchTo(rig.b, rows: Fake.rows(10..<12))

        var edited = Fake.rows(0..<4)
        edited[2] = Fake.user(2, text: "Edited while away")
        rig.switchTo(rig.a, rows: edited)
        #expect(controller.heights.count == 3)
        #expect(controller.heights["u-u2"] == nil)
        #expect(controller.heightCacheStats.restored == 3 && controller.heightCacheStats.rejected == 1)

        let measured = controller.prefetchStats.rowsMeasured
        _ = controller.measure(Array(edited.indices), width: 400, deadline: nil)
        #expect(controller.prefetchStats.rowsMeasured == measured + 1)
    }

    @Test func settingsInvalidationClearsTheCache() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let rig = self.rig(scratch)
        let controller = rig.controller
        let rows = Fake.rows(0..<4)
        _ = controller.accept(rows, contextChanged: false)
        self.measureAll(controller)
        rig.switchTo(rig.b, rows: Fake.rows(10..<12))
        #expect(controller.heightCache.keys == [rig.a.sessionKey])

        controller.invalidate(nil, keepInPlace: nil)
        #expect(controller.heightCache.count == 0)
        rig.switchTo(rig.a, rows: rows)
        #expect(controller.heights.isEmpty)
    }

    @Test func dehydratedChatIsPruned() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let rig = self.rig(scratch)
        let controller = rig.controller
        let rows = Fake.rows(0..<4)
        _ = controller.accept(rows, contextChanged: false)
        self.measureAll(controller)
        rig.switchTo(rig.b, rows: Fake.rows(10..<12))
        #expect(controller.heightCache.peek(rig.a.sessionKey) != nil)

        rig.a.chat?.hasLoaded = false
        self.measureAll(controller)
        // The next stash prunes chats that are no longer hydrated.
        rig.switchTo(rig.a, rows: rows)
        #expect(controller.heightCache.peek(rig.a.sessionKey) == nil)
        #expect(controller.heights.isEmpty)
    }

    @Test func releasedChatIsPruned() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let rig = self.rig(scratch)
        let controller = rig.controller
        _ = controller.accept(Fake.rows(0..<4), contextChanged: false)
        self.measureAll(controller)
        weak var released: ChatStore?
        do {
            let ephemeral = ChatStore(sessionKey: "agent:list:gone", agentId: nil, gateway: rig.gateway)
            ephemeral.hasLoaded = true
            released = ephemeral
            let gone = TranscriptContext(gateway: rig.gateway, disclosure: TranscriptDisclosure(), agent: rig.a.agent,
                                         sessionKey: "agent:list:gone", previewImage: { _ in }, saveFile: { _, _ in },
                                         chat: ephemeral)
            rig.switchTo(gone, rows: Fake.rows(20..<23))
            self.measureAll(controller)
        }
        // Switching away stashes it; the snapshot holds the chat weakly.
        rig.switchTo(rig.a, rows: Fake.rows(0..<4))
        #expect(released == nil)
        #expect(controller.heightCache.peek("agent:list:gone") != nil)
        rig.switchTo(rig.b, rows: Fake.rows(10..<12))
        #expect(controller.heightCache.peek("agent:list:gone") == nil)
    }

    @Test func widthChangeKeepsRestoredHeightsAsNonCurrent() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let rig = self.rig(scratch)
        let controller = rig.controller
        let rows = Fake.rows(0..<4)
        _ = controller.accept(rows, contextChanged: false)
        self.measureAll(controller)
        let originals = controller.heights
        rig.switchTo(rig.b, rows: Fake.rows(10..<12))
        rig.switchTo(rig.a, rows: rows)

        #expect(controller.heights["u-u0"]?.isCurrent(at: 400) == true)
        #expect(controller.heights["u-u0"]?.isCurrent(at: 500) == false)
        #expect(controller.heights["u-u0"]?.value == originals["u-u0"]?.value)
        let measured = controller.prefetchStats.rowsMeasured
        let result = controller.measure(Array(rows.indices), width: 500, deadline: nil)
        #expect(result.changed.count <= rows.count)
        #expect(controller.prefetchStats.rowsMeasured == measured + rows.count)
    }

    @Test func cacheIsBoundedByTheLimit() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let rig = self.rig(scratch)
        let controller = rig.controller
        var contexts: [TranscriptContext] = [rig.a]
        let limit = ResidentChatCache<Int>.defaultLimit
        for n in 0..<(limit + 3) {
            let key = "agent:list:extra\(n)"
            let chat = rig.gateway.chat(for: key)
            chat.hasLoaded = true
            contexts.append(TranscriptContext(gateway: rig.gateway, disclosure: TranscriptDisclosure(), agent: rig.a.agent,
                                              sessionKey: key, previewImage: { _ in }, saveFile: { _, _ in }, chat: chat))
        }
        _ = controller.accept(Fake.rows(0..<3), contextChanged: false)
        for context in contexts.dropFirst() {
            self.measureAll(controller)
            rig.switchTo(context, rows: Fake.rows(0..<3))
            #expect(controller.heightCache.count <= limit)
        }
        #expect(controller.heightCache.peek(rig.a.sessionKey) == nil)
    }
}
