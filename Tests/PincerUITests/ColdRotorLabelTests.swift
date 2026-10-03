#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Cold rotor label cost", .serialized)
struct ColdRotorLabelTests {
    @MainActor private final class Host {
        let scratch = ScratchDefaults()
        let gateway: GatewayStore
        let coordinator: TranscriptList.Coordinator
        let scroll: NSScrollView
        let table: NSTableView
        let row: TranscriptRow
        let context: TranscriptContext

        init(row: TranscriptRow, agentName: String = "Rotor agent") throws {
            self.row = row
            self.gateway = GatewayStore(
                profile: GatewayProfile(name: "Cold rotor", url: "ws://127.0.0.1:1", authMode: .none),
                defaults: self.scratch.defaults, identity: UIFixtures.identity())
            self.gateway.cacheRoot = nil
            let key = "agent:main:cold-rotor"
            self.context = TranscriptContext(
                gateway: self.gateway, disclosure: TranscriptDisclosure(),
                agent: AgentSummary(id: "main", name: agentName), sessionKey: key,
                previewImage: { _ in }, saveFile: { _, _ in }, chat: self.gateway.chat(for: key))
            let context = self.context
            self.coordinator = TranscriptList.Coordinator(context: context)
            self.scroll = self.coordinator.makeScrollView()
            self.table = try #require(self.scroll.documentView as? NSTableView)
            self.scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 0)
            self.coordinator.update(rows: [row], context: context, insets: (0, 0))
            try #require(self.table.numberOfRows == 1)
            // Initial table settling may warm a user layout even without a viewport. Use the
            // renderer's real cache reset and cancel its epoch before testing cold enumeration.
            self.coordinator.controller.premeasure.cancelAll()
            self.coordinator.renderer.reset()
        }

        func search() throws -> NSAccessibilityCustomRotor.ItemResult? {
            let rotor = try #require(self.table.accessibilityCustomRotors().first { $0.label == "Messages" })
            let installedDelegate: (any NSAccessibilityCustomRotorItemSearchDelegate)? = rotor.itemSearchDelegate
            let delegate = try #require(installedDelegate)
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.filterString = ""
            parameters.searchDirection = .next
            parameters.currentItem = nil
            return delegate.rotor(rotor, resultFor: parameters)
        }

        func stop() {
            self.coordinator.controller.premeasure.cancelAll()
            self.gateway.stop()
            self.scratch.remove()
        }
    }

    private nonisolated static func user(_ id: String, blocks: [ContentBlock]) -> TranscriptRow {
        var item = ChatItem(id: id, role: .user, blocks: blocks,
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        item.transcriptId = id
        return .entry(.user(item))
    }

    private nonisolated static func assistant(_ id: String, text: String) -> TranscriptRow {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var turn = AssistantTurn(id: id, timestamp: stamp)
        turn.text = [text]
        turn.textTimestamps = [stamp]
        turn.textModelNames = [nil]
        turn.textIds = [id]
        return .entry(.assistant(turn))
    }

    @Test(.timeLimit(.minutes(2))) func actualColdUserRotorDoesNotJoinLargeTextOnMain() async throws {
        let row = await Task.detached {
            let block = String(repeating: "Multiblock text ", count: 4_400)
            return Self.user("cold-user-large", blocks: [.text("Cold user opening")] +
                (0..<32).map { _ in .text(block) })
        }.value
        let host = try Host(row: row)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: row) == nil
        try #require(isCold, "Exercise the actual cold cache-miss path without dumping a large label")
        try #require(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let cachedCount = host.coordinator.renderer.cachedLayoutCount
        let result = try #require(try host.search())
        #expect(result.itemLoadingToken as? String == row.id)
        #expect(result.customLabel?.contains(AccessibilityText.speaker(role: .user)) == true)
        #expect(result.customLabel?.contains("Cold user opening") == true)
        #expect(probe.mainFullTextJoins == 0, "Actual rotor enumeration must never join the full user message on Main")
        #expect(probe.mainCharacterPrefixes == 0, "Actual cold text cannot traverse an unbounded grapheme prefix")
        #expect(probe.captures.count == 1)
        #expect(probe.captures.first?.bodyBytes == 400)
        #expect(probe.captures.first?.authorBytes == 0)
        #expect((probe.captures.first?.visitedBlocks ?? 65) <= 64)
        #expect(host.coordinator.renderer.cachedLayoutCount == cachedCount)
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        #expect(host.coordinator.controller.navigationRowId == nil)
    }

    @Test(.timeLimit(.minutes(2))) func actualColdAssistantRotorBoundsGiantGraphemeOpening() async throws {
        let row = await Task.detached {
            let text = "e" + String(repeating: "\u{301}", count: 1_048_576) + " closing"
            return Self.assistant("cold-assistant-cluster", text: text)
        }.value
        let host = try Host(row: row)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: row) == nil
        try #require(isCold)
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let result = try #require(try host.search())
        #expect(result.itemLoadingToken as? String == row.id)
        let label = try #require(result.customLabel)
        #expect(label.contains("Rotor agent"))
        #expect(label.unicodeScalars.contains { $0.value == 0x65 }, "Retain the real opening base scalar")
        let isBounded = label.utf8.count <= 512
        #expect(isBounded, "A single grapheme cannot expand the cold spoken label to megabytes")
        #expect(probe.mainCharacterPrefixes == 0)
        #expect(probe.captures.first?.bodyBytes == 400)
        #expect(probe.captures.first?.authorBytes == "Rotor agent".utf8.count)
        #expect(probe.captures.first?.visitedBlocks == 1)
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        #expect(host.coordinator.controller.navigationRowId == nil)
    }

    @Test(.timeLimit(.minutes(2))) func actualColdAssistantRotorBoundsAuthorBeforeFormatting() async throws {
        let fixture = await Task.detached {
            (row: Self.assistant("cold-author-cluster", text: "Cold assistant opening"),
             author: "A" + String(repeating: "\u{301}", count: 1_048_576))
        }.value
        let host = try Host(row: fixture.row, agentName: fixture.author)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: fixture.row) == nil
        try #require(isCold)
        let probe = ColdRotorLabelProbe(rowIDs: [fixture.row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let result = try #require(try host.search())
        let label = try #require(result.customLabel)
        #expect(result.itemLoadingToken as? String == fixture.row.id)
        #expect(label.contains("Cold assistant opening"))
        #expect(label.unicodeScalars.contains { $0.value == 0x41 })
        let isBounded = label.utf8.count <= 544
        #expect(isBounded, "Bound author bytes before speaker formatting, independently of the opening text")
        #expect(probe.mainAuthorFormattings == 0)
        #expect(probe.captures.first?.authorBytes == 128)
        #expect(probe.captures.first?.bodyBytes == "Cold assistant opening".utf8.count)
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        #expect(host.coordinator.controller.navigationRowId == nil)
    }

    @Test(.timeLimit(.minutes(2))) func actualColdShortMultiblockOpeningKeepsUsefulSeparatedText() throws {
        let row = Self.user("cold-short-blocks", blocks: [.text("First opening"), .text("Second block")])
        let host = try Host(row: row)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: row) == nil
        try #require(isCold)
        let result = try #require(try host.search())
        let label = try #require(result.customLabel)
        #expect(result.itemLoadingToken as? String == row.id)
        #expect(label.contains("First opening") && label.contains("Second block"))
        #expect(!label.contains("openingSecond"), "Adjacent text blocks retain a separator")
        #expect(label.contains(AccessibilityText.speaker(role: .user)))
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
    }

    @Test func exactProbePositiveControl() {
        let probe = ColdRotorLabelProbe(rowIDs: ["control"])
        probe.record(.fullTextJoin, rowID: "untracked")
        #expect(probe.mainFullTextJoins == 0)
        probe.record(.fullTextJoin, rowID: "control")
        probe.record(.characterPrefix, rowID: "control")
        #expect(probe.mainFullTextJoins == 1)
        #expect(probe.mainCharacterPrefixes == 1)
    }

    private nonisolated static func foreignUTF16() -> String {
        Array(repeating: UInt16(0x00E9), count: 512).withUnsafeBufferPointer {
            NSString(characters: $0.baseAddress!, length: $0.count) as String
        }
    }

    @Test(.timeLimit(.minutes(2))) func actualForeignBodyAndAuthorUseMetadataFallbackWithoutConversion() async throws {
        let foreign = await Task.detached { Self.foreignUTF16() }.value
        let isForeign = !foreign.isContiguousUTF8
        try #require(isForeign, "Establish actual foreign UTF16 storage before testing admission")
        let row = Self.user("cold-foreign-body", blocks: [.text(foreign)])
        let host = try Host(row: row)
        defer { host.stop() }
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let result = try #require(try host.search())
        let isUserFallback = result.customLabel == AccessibilityText.speaker(role: .user)
        #expect(isUserFallback)
        #expect(result.itemLoadingToken as? String == row.id)
        #expect(probe.captures.first?.bodyBytes == 0)
        #expect(probe.captures.first?.visitedBlocks == 1)
        #expect(probe.mainFullTextJoins == 0 && probe.mainCharacterPrefixes == 0)

        let assistant = Self.assistant("cold-foreign-author", text: "Foreign author opening")
        let authorHost = try Host(row: assistant, agentName: foreign)
        defer { authorHost.stop() }
        let authorProbe = ColdRotorLabelProbe(rowIDs: [assistant.id])
        authorHost.coordinator.coldRotorLabelProbe = authorProbe
        let authorResult = try #require(try authorHost.search())
        let authorLabel = try #require(authorResult.customLabel)
        let usesDefaultSpeaker = authorLabel.contains(AccessibilityText.speaker(role: .assistant))
        #expect(usesDefaultSpeaker)
        #expect(authorLabel.contains("Foreign author opening"))
        #expect(authorProbe.captures.first?.authorBytes == 0)
        #expect(authorProbe.mainAuthorFormattings == 0)
    }

    @Test(.timeLimit(.minutes(2))) func actualUnicodeOpeningPreservesScalarsAndClipsOnlyIncompleteTail() throws {
        let examples: [(id: String, text: String, expected: String, bytes: Int)] = [
            ("literal-replacement", "Literal � ending", "Literal � ending", "Literal � ending".utf8.count),
            ("supplementary", "Opening 😀 ending", "Opening 😀 ending", "Opening 😀 ending".utf8.count),
            ("clipped-scalar", String(repeating: "a", count: 399) + "😀 beyond", "aaaa", 400),
        ]
        for example in examples {
            let row = Self.user("cold-" + example.id, blocks: [.text(example.text)])
            let host = try Host(row: row)
            defer { host.stop() }
            let probe = ColdRotorLabelProbe(rowIDs: [row.id])
            host.coordinator.coldRotorLabelProbe = probe
            let result = try #require(try host.search())
            let label = try #require(result.customLabel)
            let retainsOpening = label.contains(example.expected)
            #expect(retainsOpening)
            if example.id == "clipped-scalar" {
                let hasReplacement = label.unicodeScalars.contains { $0.value == 0xFFFD }
                #expect(!hasReplacement, "A clipped UTF8 scalar cannot become a synthetic replacement character")
            }
            #expect(probe.captures.first?.bodyBytes == example.bytes)
            #expect(probe.captures.first?.visitedBlocks == 1)
            #expect(probe.mainFullTextJoins == 0 && probe.mainCharacterPrefixes == 0)
            #expect(result.itemLoadingToken as? String == row.id)
        }
    }

    @Test(.timeLimit(.minutes(2))) func actualTagBudgetAndSameIdentityEditUseCurrentSource() throws {
        let row = Self.user("cold-tag-budget", blocks: Array(repeating: .text(""), count: 64) + [.text("Outside tag budget")])
        let host = try Host(row: row)
        defer { host.stop() }
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let result = try #require(try host.search())
        let label = try #require(result.customLabel)
        let includesUninspectedText = label.contains("Outside tag budget")
        #expect(!includesUninspectedText)
        #expect(probe.captures.first?.visitedBlocks == 64)
        #expect((probe.captures.first?.bodyBytes ?? 401) <= 400)
        #expect(label.contains(AccessibilityText.speaker(role: .user)))

        let edited = Self.user("cold-tag-budget", blocks: [.text("Current edited opening")])
        try #require(edited.id == row.id)
        host.coordinator.update(rows: [edited], context: host.context, insets: (0, 0))
        host.coordinator.controller.premeasure.cancelAll()
        host.coordinator.renderer.reset()
        let current = try #require(try host.search())
        let currentLabel = try #require(current.customLabel)
        #expect(currentLabel.contains("Current edited opening"))
        #expect(current.itemLoadingToken as? String == row.id)
        #expect(probe.captures.count == 2)
        #expect(probe.captures.last?.bodyBytes == "Current edited opening".utf8.count)
        #expect(probe.captures.last?.visitedBlocks == 1)
        #expect(probe.mainFullTextJoins == 0 && probe.mainCharacterPrefixes == 0)
    }

    @Test(.timeLimit(.minutes(2))) func actualWarmRendererAndMaterializedCellKeepFullNativeLabels() throws {
        let row = Self.user("rotor-warm-control", blocks: [.text("**Warm** opening control")])
        let host = try Host(row: row)
        defer { host.stop() }
        let layout = host.coordinator.renderer.layout(for: row, width: 600)
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let count = host.coordinator.renderer.cachedLayoutCount
        let token = try #require(try host.search())
        #expect(token.itemLoadingToken as? String == row.id)
        #expect(token.customLabel == layout.accessibilityLabel)
        #expect(probe.mainFullTextJoins == 0 && probe.mainCharacterPrefixes == 0)
        #expect(probe.captures.isEmpty, "Warm renderer labels bypass bounded cold capture")
        #expect(host.coordinator.renderer.cachedLayoutCount == count)
        let cell = try #require(host.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let materializedCount = host.coordinator.renderer.cachedLayoutCount
        let target = try #require(try host.search())
        #expect(target.targetElement as? NSView === cell)
        #expect(target.customLabel == layout.accessibilityLabel)
        #expect(host.coordinator.renderer.cachedLayoutCount == materializedCount)
        #expect(probe.mainFullTextJoins == 0 && probe.mainCharacterPrefixes == 0)
        #expect(probe.captures.isEmpty, "Materialized native labels bypass bounded cold capture")
        #expect(host.coordinator.controller.navigationRowId == nil)
    }
}
#endif
