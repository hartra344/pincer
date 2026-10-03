#if os(iOS)
import CoreGraphics
import Foundation
import Synchronization
@testable import PincerKit
import Testing
import UIKit
@testable import PincerUI

private actor SpeechPreparationGate {
    private let messageID: String
    private var claimed = false
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Bool, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entryTimeout: Task<Void, Never>?

    init(messageID: String) { self.messageID = messageID }

    func hold(_ messageID: String) async {
        guard messageID == self.messageID, !self.claimed else { return }
        self.claimed = true
        self.entered = true
        self.entryTimeout?.cancel()
        self.entryTimeout = nil
        self.enteredContinuation?.resume(returning: true)
        self.enteredContinuation = nil
        await withCheckedContinuation { continuation in
            if self.released {
                continuation.resume()
            } else {
                self.releaseContinuation = continuation
            }
        }
    }

    func waitUntilEntered(timeout: Duration) async -> Bool {
        if self.entered { return true }
        return await withCheckedContinuation { continuation in
            self.enteredContinuation = continuation
            self.entryTimeout = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self.expireEntryWait()
            }
        }
    }

    func release() {
        self.released = true
        self.entryTimeout?.cancel()
        self.entryTimeout = nil
        let continuation = self.releaseContinuation
        self.releaseContinuation = nil
        continuation?.resume()
    }

    private func expireEntryWait() {
        self.entryTimeout = nil
        let continuation = self.enteredContinuation
        self.enteredContinuation = nil
        continuation?.resume(returning: false)
    }
}

/// The UIKit counterpart of `TranscriptPremeasureHosted` (#434): a hosted `UICollectionView` list with counter-based
/// checks of the off-main path (no wall-clock assertions). Scrolling is driven through `readerScrolled`, which is what
/// `scrollViewDidScroll` calls for a real drag.
@MainActor
@Suite("TranscriptPremeasureHostedUIKit", .serialized)
struct TranscriptUIKitHostedTests {
    /// Tearing the collection view down mid-test is avoided the same way as on macOS: the tests keep their windows.
    static var keepAlive: [(UIWindow, TranscriptList.Coordinator)] = []

    @MainActor struct Host {
        let coordinator: TranscriptList.Coordinator
        let view: UICollectionView
        let context: TranscriptContext
    }

    static func makeHost(size: CGSize = CGSize(width: 390, height: 844)) async -> Host {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:probe:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let coordinator = TranscriptList.Coordinator(context: context)
        let view = coordinator.makeCollectionView()
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        Self.keepAlive.append((window, coordinator))
        return Host(coordinator: coordinator, view: view, context: context)
    }

    static func driver(_ coordinator: TranscriptList.Coordinator) -> TranscriptPremeasureDriver {
        coordinator.controller.premeasure
    }

    @Test func floatingPillReserveReachesTheNativeTranscriptInsets() async {
        let host = await Self.makeHost()
        // A representative fractional reserve exercises the native scrolling and indicator insets.
        let pillReserve: CGFloat = 47.5
        host.coordinator.update(rows: [], context: host.context, insets: (0, pillReserve))
        #expect(abs(host.view.contentInset.bottom - TranscriptLayout.verticalInset - pillReserve) < 0.5)
        #expect(abs(host.view.verticalScrollIndicatorInsets.bottom - pillReserve) < 0.5)
    }

    @Test func homeChatGroupMenuNamesTheOrganizationWhereTheGroupAppears() throws {
        try SidebarHomeGroupMenuTests.verifyMenuCaptions()
    }

    @Test func webSearchTruncationStatusReachesUIKitTranscriptLayout() throws {
        try WebSearchTruncationStatusTests.verifyResultsStatus()
        try WebSearchTruncationStatusTests.verifyAnswerStatus()
    }

    @Test func demoAttachmentPreparationUsesTheSharedQueueAndCommitsAnImage() async throws {
        try await AttachmentPreparationTests.verifyDemoChatDraftPreparesAndSendsAnOversizedImage()
    }

    @Test func webSearchSnippetUsesAtMostTwoVisibleLinesAtCompactWidth() async throws {
        let host = await Self.makeHost(size: CGSize(width: 360, height: 844))
        let turnID = "snippet-lines-turn-\(UUID().uuidString)"
        let toolID = "snippet-lines-tool-\(UUID().uuidString)"
        let snippet = try #require(DemoGateway.toolCardsSearchResults.first?.snippet,
                                   "the native fixture uses the realistic long snippet already seeded in Try the Demo")
        let tool = ToolActivity(
            id: toolID, name: "web_search", arguments: "{}", result: "search results",
            details: .object([
                "kind": .string("results"), "provider": .string("brave"),
                "results": .array([.object([
                    "title": .string("Guide"), "url": .string("https://docs.example/guide"),
                    "siteName": .string("docs.example"), "snippet": .string(snippet),
                ])]),
            ]),
            isError: false, isRunning: false)
        var turn = AssistantTurn(id: turnID, timestamp: Date(timeIntervalSince1970: 1))
        turn.text = ["Search source follows."]
        turn.tools = [tool]
        turn.isStreaming = true
        host.context.disclosure.set("steps:\(turnID)", expanded: true)
        host.context.disclosure.set("tool:\(toolID)", expanded: true)
        host.coordinator.update(rows: [.entry(.assistant(turn))], context: host.context, insets: (0, 0))
        await Self.idle(host, cap: 10)
        host.view.layoutIfNeeded()

        let row = try #require(host.coordinator.controller.rows.first)
        let rowLayout = host.coordinator.renderer.layout(for: row, width: host.view.bounds.width)
        let toolParts = rowLayout.parts.compactMap { placed -> TranscriptPart.Tool? in
            guard case let .tool(toolPart) = placed.part else { return nil }
            return toolPart
        }
        let toolPart = try #require(toolParts.first, "the expanded web_search card is in the actual transcript row")
        let visibleCell = try #require(host.view.cellForItem(at: IndexPath(item: 0, section: 0)))
        func descendants(_ root: UIView) -> [UIView] {
            [root] + root.subviews.flatMap(descendants)
        }
        let displayedSnippet = try #require(WebSearch.parse(tool.details)?.results.first?.snippet,
                                            "the native view retains the complete parsed snippet, including its clipping ellipsis")
        let snippetSections = toolPart.sections.filter { $0.text.string.contains(displayedSnippet) }
        #expect(!snippetSections.isEmpty,
                "the complete capped snippet remains in the rendered source used by Find")
        // Locate the native TextKit view by the exact retained snippet instead of assuming title, site and
        // snippet share one section. This supports either a combined section or a split compact layout.
        let snippetViews = descendants(visibleCell).compactMap { $0 as? TranscriptTextView }
            .filter { ($0.accessibilityValue ?? "").contains(displayedSnippet) }
        let renderedTextViews = descendants(visibleCell).compactMap { $0 as? TranscriptTextView }

        func isVisible(_ value: String) -> Bool {
            renderedTextViews.contains { candidate in
                let text = candidate.accessibilityValue ?? ""
                let characterRange = (text as NSString).range(of: value)
                guard characterRange.location != NSNotFound else { return false }
                let layoutManager = candidate.layoutManager
                let textContainer = candidate.textContainer
                layoutManager.ensureLayout(for: textContainer)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
                let visibleRange = layoutManager.glyphRange(forBoundingRect: candidate.bounds, in: textContainer)
                return NSIntersectionRange(glyphRange, visibleRange).length > 0
            }
        }
        #expect(isVisible("Guide") && isVisible("docs.example"),
                "the linked title and site remain visibly rendered across the result sections")
        let textView = try #require(snippetViews.first,
                                    "the actual UIKit text view retains the complete capped snippet")
        #expect(snippetViews.count == 1, "the visible result renders the snippet in one native text view")
        let text = textView.accessibilityValue ?? ""
        let snippetRange = (text as NSString).range(of: displayedSnippet)
        #expect(snippetRange.location != NSNotFound)
        #expect(textView.bounds.width > 0 && textView.bounds.width < 360,
                "the snippet view is laid out at the compact host's actual content width")

        // Count only line fragments intersecting the snippet's glyphs and visible text container bounds.
        // Header/site line fragments in a combined section do not count against the two-line snippet limit.
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        layoutManager.ensureLayout(for: textContainer)
        let snippetGlyphs = layoutManager.glyphRange(forCharacterRange: snippetRange, actualCharacterRange: nil)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.bounds, in: textContainer)
        let visibleSnippetGlyphs = NSIntersectionRange(snippetGlyphs, visibleGlyphs)
        var visibleSnippetLines = 0
        layoutManager.enumerateLineFragments(forGlyphRange: visibleSnippetGlyphs) { _, _, _, lineGlyphs, _ in
            if NSIntersectionRange(lineGlyphs, visibleSnippetGlyphs).length > 0 {
                visibleSnippetLines += 1
            }
        }
        #expect(visibleSnippetLines > 0, "the snippet has visible native TextKit line fragments")
        #expect(visibleSnippetLines <= 2,
                "the compact preview shows at most two snippet lines; got \(visibleSnippetLines)")
        #expect(!textView.isScrollEnabled, "the result preview does not require a nested scroll gesture")
    }

    @Test func loggedOutBadgeContrastMeetsLightAndDarkFormSurfaces() throws {
        try LoggedOutBadgeContrastTests.verifyContrast()
    }

    @Test func visibleReadAloudEligibilityDoesNotNormalizeTheBodyOnMain() async throws {
        let host = await Self.makeHost()
        let messageID = "read-aloud-eligibility-\(UUID().uuidString)"
        let body = String(repeating: "A **formatted reply** with `code` and a [source](https://example.test).\n\n", count: 80)
        var item = ChatItem(id: messageID, role: .assistant, blocks: [.text(body)])
        item.transcriptId = messageID
        let chat = try #require(host.context.chat)
        chat.items = [item]

        SpeechText.resetSpeakabilityDebugStats(tracking: messageID)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: messageID) }
        host.coordinator.update(rows: [Self.assistant(messageID, text: body, at: 1)], context: host.context, insets: (0, 0))
        await Self.idle(host, cap: 10)
        host.view.layoutIfNeeded()

        let cell = try #require(host.view.visibleCells.first)
        func hasVisibleReadAloud(in root: UIView) -> Bool {
            var pending = [root]
            while let view = pending.popLast() {
                if let button = view as? TranscriptLabelButton,
                   button.accessibilityText == "Read Aloud", !button.isHidden { return true }
                pending.append(contentsOf: view.subviews)
            }
            return false
        }
        let layoutBuildCountBeforeReadiness = host.coordinator.renderer.layoutBuildCount
        let firstReady = await eventually(timeout: .seconds(3)) {
            host.view.layoutIfNeeded()
            return host.view.visibleCells.contains(where: hasVisibleReadAloud)
        }
        #expect(firstReady && hasVisibleReadAloud(in: cell), "normal assistant prose keeps the actual Listen button after preparation")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).mainThreadNormalizations == 0,
                "visible-row and accessibility configuration should consume prepared eligibility rather than parse the body on main")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations == 1,
                "a visible cache miss is normalized once by the background worker")
        #expect(host.coordinator.renderer.layoutBuildCount == layoutBuildCountBeforeReadiness,
                "readiness refresh advances the native apply token without rebuilding row geometry")

        host.view.reloadData()
        host.view.layoutIfNeeded()
        await Self.idle(host, cap: 10)
        #expect(SpeechText.speakabilityDebugStats(for: messageID).mainThreadNormalizations == 0,
                "reconfiguring an unchanged visible item should reuse its eligibility")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations == 1,
                "reconfiguring an unchanged visible item should not repeat background normalization")

        // A different row advances the chat's coarse revision, but the unchanged assistant source
        // remains prepared; eligibility lookup must not re-normalize every visible reply.
        let unrelatedID = "read-aloud-unrelated-\(UUID().uuidString)"
        var unrelated = ChatItem(id: unrelatedID, role: .user, blocks: [.text("A separate question")])
        unrelated.transcriptId = unrelatedID
        chat.items = [item, unrelated]
        host.coordinator.update(rows: [Self.assistant(messageID, text: body, at: 1), .entry(.user(unrelated))],
                                context: host.context, insets: (0, 0))
        await Self.idle(host, cap: 10)
        host.view.layoutIfNeeded()
        #expect(host.view.visibleCells.contains(where: hasVisibleReadAloud),
                "an unrelated row update keeps the existing assistant Listen action available")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations == 1,
                "an unrelated chat revision does not re-normalize the unchanged assistant body")

        // A changed item under the same transcript id must not leave stale eligibility behind.
        let codeOnly = "```swift\nlet answer = 42\n```"
        item.blocks = [.text(codeOnly)]
        chat.items = [item]
        host.coordinator.update(rows: [Self.assistant(messageID, text: codeOnly, at: 2)], context: host.context, insets: (0, 0))
        await Self.idle(host, cap: 10)
        host.view.layoutIfNeeded()
        let codeReady = await eventually(timeout: .seconds(3)) {
            host.view.layoutIfNeeded()
            return SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations >= 2
        }
        let codeCell = try #require(host.view.visibleCells.first)
        #expect(codeReady && !hasVisibleReadAloud(in: codeCell), "code-only assistant content is not speakable")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).mainThreadNormalizations == 0,
                "content changes should refresh eligibility off main")

        item.blocks = [.text(body + "\n\nA restored answer.")]
        chat.items = [item]
        let restoredRow = Self.assistant(messageID, text: item.plainText, at: 3)
        host.coordinator.update(rows: [restoredRow], context: host.context, insets: (0, 0))
        await Self.idle(host, cap: 10)
        host.view.layoutIfNeeded()
        let restoredReady = await eventually(timeout: .seconds(3)) {
            host.view.layoutIfNeeded()
            return SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations >= 3
                && host.view.visibleCells.contains(where: hasVisibleReadAloud)
        }
        let restoredCell = try #require(host.view.visibleCells.first)
        #expect(restoredReady && hasVisibleReadAloud(in: restoredCell), "restored prose is eligible again")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).mainThreadNormalizations == 0,
                "restoring content must also use the prepared off-main eligibility")

        // A style/context-wide reset drops both layout identity and readiness. If the store edits
        // the same ID before the replacement row projection arrives, old prose must not leak back.
        host.coordinator.renderer.reset()
        item.blocks = [.text(codeOnly)]
        chat.items = [item]
        _ = host.coordinator.renderer.layout(for: restoredRow, width: max(1, host.view.bounds.width))
        #expect(!host.coordinator.renderer.canReadAloud(messageID, rowID: restoredRow.id),
                "a reset cannot reuse readiness after an edit made before the next row projection")
    }

    @Test func staleSameIDPreparationCannotRestoreSpeakabilityAfterAnEdit() async throws {
        let host = await Self.makeHost()
        let messageID = "read-aloud-stale-\(UUID().uuidString)"
        let prose = String(repeating: "A finished assistant answer. ", count: 40)
        let codeOnly = "```swift\nlet answer = 42\n```"
        var item = ChatItem(id: messageID, role: .assistant, blocks: [.text(prose)])
        item.transcriptId = messageID
        let chat = try #require(host.context.chat)
        chat.items = [item]

        let gate = SpeechPreparationGate(messageID: messageID)
        host.coordinator.renderer.speechPreparationGate = { id in await gate.hold(id) }
        defer {
            host.coordinator.renderer.speechPreparationGate = nil
            Task { await gate.release() }
        }
        SpeechText.resetSpeakabilityDebugStats(tracking: messageID)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: messageID) }
        host.coordinator.update(rows: [Self.assistant(messageID, text: prose, at: 1)], context: host.context, insets: (0, 0))
        let started = await gate.waitUntilEntered(timeout: .seconds(4))
        guard started else {
            await gate.release()
            #expect(Bool(false), "the real renderer starts background preparation")
            return
        }

        // Hold longer than the former four-second semaphore auto-release. This bounded causal
        // check proves the real worker remains paused before the same-ID edit below.
        try? await Task.sleep(for: .seconds(5))
        let stillHeld = SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations == 0
        #expect(stillHeld, "the worker must still be held for the actual stale-completion fixture")
        guard stillHeld else {
            await gate.release()
            return
        }

        // The store now owns different content under the same transcript ID, while the native row
        // still holds its old projection. This is the interval in which stale work must be rejected.
        item.blocks = [.text(codeOnly)]
        chat.items = [item]
        await gate.release()
        let refreshed = await eventually(timeout: .seconds(4)) {
            host.view.layoutIfNeeded()
            return SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations >= 2
                && host.view.visibleCells.allSatisfy { cell in
                    var pending: [UIView] = [cell]
                    while let view = pending.popLast() {
                        if let button = view as? TranscriptLabelButton,
                           button.accessibilityText == "Read Aloud", !button.isHidden { return false }
                        pending.append(contentsOf: view.subviews)
                    }
                    return true
                }
        }
        #expect(refreshed, "a stale prose result is replaced by the current same-ID code-only result")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).mainThreadNormalizations == 0,
                "stale completion and its retry never normalize on main")
    }

    @Test func boundedSpeechWorkerQueueEventuallyPreparesVisibleRowsAfterInvalidation() async throws {
        let host = await Self.makeHost()
        let chat = try #require(host.context.chat)
        let count = 18
        var items: [ChatItem] = []
        var rows: [TranscriptRow] = []
        for index in 0..<count {
            let id = "read-aloud-queued-\(UUID().uuidString)-\(index)"
            let text = "Finished assistant answer number \(index)."
            var item = ChatItem(id: id, role: .assistant, blocks: [.text(text)])
            item.transcriptId = id
            items.append(item)
            rows.append(Self.assistant(id, text: text, at: index))
        }
        chat.items = items
        let renderer = host.coordinator.renderer
        let width = max(1, host.view.bounds.width)
        let preparedIDs = Mutex(Set<String>())
        renderer.speechPreparationProbe = { id in
            _ = preparedIDs.withLock { $0.insert(id) }
        }
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))

        for (item, row) in zip(items, rows) {
            _ = renderer.layout(for: row, width: width)
            #expect(!renderer.canReadAloud(item.id, rowID: row.id), "a cold row waits for prepared eligibility")
        }
        #expect(renderer.pendingSpeechPreparationCount == count - 16,
                "rows beyond the active worker cap enter the bounded FIFO")
        #expect(renderer.pendingSpeechPreparationOrderCount <= TranscriptRenderer.layoutCacheLimit * 2,
                "FIFO tombstones have a strict storage bound")

        // Replace one deferred row under the same ID before it reaches the serial worker. Its stale
        // queue token must not consume the replacement request.
        let replacedIndex = count - 1
        let replacedID = items[replacedIndex].id
        let codeOnly = "```swift\nlet answer = 42\n```"
        items[replacedIndex].blocks = [.text(codeOnly)]
        chat.items = items
        let replacementRow = Self.assistant(replacedID, text: codeOnly, at: count + 1)
        rows[replacedIndex] = replacementRow
        _ = renderer.layout(for: replacementRow, width: width)
        #expect(!renderer.canReadAloud(replacedID, rowID: replacementRow.id),
                "the replacement source queues after invalidating its earlier deferred request")

        let allPrepared = await eventually(timeout: .seconds(8)) {
            let allCurrentEligibility = zip(items, rows).enumerated().allSatisfy { indexedPair in
                let eligible = renderer.canReadAloud(indexedPair.element.0.id, rowID: indexedPair.element.1.id)
                return indexedPair.offset == replacedIndex ? !eligible : eligible
            }
            return allCurrentEligibility && renderer.activeSpeechPreparationCount == 0
                && renderer.pendingSpeechPreparationCount == 0
        }
        #expect(allPrepared, "completed jobs drain the FIFO until every current visible row is prepared")
        #expect(preparedIDs.withLock { $0.count == count },
                "the replacement ID receives fresh work rather than being consumed by its stale FIFO token")
        #expect(renderer.pendingSpeechPreparationCount == 0, "the bounded queue drains after worker completion")
        #expect(!renderer.canReadAloud(replacedID, rowID: replacementRow.id),
                "the current code-only replacement remains ineligible after its queue entry runs")
    }

    @Test func activePreparationRetargetsWhenTheSameRowGetsANewLayoutSerial() async throws {
        let host = await Self.makeHost()
        let messageID = "read-aloud-layout-serial-\(UUID().uuidString)"
        let text = String(repeating: "A finished reply with a stable source. ", count: 20)
        var item = ChatItem(id: messageID, role: .assistant, blocks: [.text(text)])
        item.transcriptId = messageID
        let chat = try #require(host.context.chat)
        chat.items = [item]
        let row = Self.assistant(messageID, text: text, at: 1)
        let renderer = host.coordinator.renderer
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        renderer.speechPreparationProbe = { _ in
            entered.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 4)
        }
        defer { release.signal() }
        SpeechText.resetSpeakabilityDebugStats(tracking: messageID)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: messageID) }
        host.coordinator.update(rows: [row], context: host.context, insets: (0, 0))

        _ = renderer.layout(for: row, width: 280)
        #expect(!renderer.canReadAloud(messageID, rowID: row.id), "the row queues an initial preparation")
        let started = await eventually { entered.withLock { $0 } }
        #expect(started, "the worker is held before normalization")

        _ = renderer.layout(for: row, width: 320)
        #expect(!renderer.canReadAloud(messageID, rowID: row.id),
                "same-source reconfiguration retargets the active job to the new layout serial")
        release.signal()

        let ready = await eventually(timeout: .seconds(4)) {
            renderer.canReadAloud(messageID, rowID: row.id)
        }
        #expect(ready, "the valid worker result survives a geometry-only layout rebuild")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).offMainNormalizations == 1,
                "retargeting does not repeat normalization")
        #expect(SpeechText.speakabilityDebugStats(for: messageID).mainThreadNormalizations == 0,
                "the layout serial retry stays off main")
    }

    @Test func webSearchLinkVoiceOverActionsNameHostWithoutSpeakingURL() async throws {
        try await WebSearchLinkVoiceOverTests.verifyActions()
    }

    static func assistant(_ id: String, text: String, streaming: Bool = false, at n: Int) -> TranscriptRow {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(n))
        var turn = AssistantTurn(id: id, timestamp: stamp)
        turn.text = [text]
        turn.textTimestamps = [stamp]
        turn.textModelNames = [nil]
        turn.textIds = [id]
        turn.isStreaming = streaming
        return .entry(.assistant(turn))
    }

    /// Alternating user and assistant rows with `salt` in every text and id, so the text isn't already in the
    /// process-wide caches. Ids are `u<salt><n>` and `a<salt><n>`.
    static func rows(count: Int, salt: String, from start: Int = 0) -> [TranscriptRow] {
        let variants = (0..<16).map { StreamingProbe.reply(bytes: 150 + $0 * 90) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (start..<start + count).map { n in
            let stamp = base.addingTimeInterval(Double(n))
            if n % 2 == 0 {
                let text = "\(salt) Question \(n): \(variants[n % 16].prefix(120 + (n % 7) * 60))"
                var item = ChatItem(id: "u\(salt)\(n)", role: .user, blocks: [.text(text)], timestamp: stamp)
                item.transcriptId = item.id
                return .entry(.user(item))
            }
            var turn = AssistantTurn(id: "a\(salt)\(n)", timestamp: stamp)
            turn.text = ["\(salt) Reply \(n)\n\n" + variants[(n / 2) % 16]]
            turn.textTimestamps = [stamp]
            turn.textModelNames = [nil]
            turn.textIds = [turn.id]
            return .entry(.assistant(turn))
        }
    }

    /// Waits on state rather than time, so a slow runner only makes it longer: the worker has nothing in flight and the
    /// number of measured rows has held still for five 100 ms slices that used under 1 ms of main-thread CPU each
    /// (the prefetch is idle), or `cap` seconds pass.
    static func idle(_ host: Host, cap: Double = 90) async {
        let start = ProbeMeter.wall()
        var quiet = 0
        var measured = -1
        while ProbeMeter.wall() - start < cap {
            let slice = ProbeMeter.threadCPU()
            try? await Task.sleep(for: .milliseconds(100))
            let now = host.coordinator.controller.heights.values.filter(\.measured).count
            let still = now == measured && Self.driver(host.coordinator).inFlightCount == 0
            measured = now
            quiet = still && ProbeMeter.threadCPU() - slice < 0.001 ? quiet + 1 : 0
            if quiet >= 5 { break }
        }
        await Self.drained(host)
    }

    /// Waits for the worker to have nothing in flight.
    static func drained(_ host: Host) async {
        _ = await eventually(timeout: .seconds(30)) { Self.driver(host.coordinator).inFlightCount == 0 }
    }

    static func scrollSteps(_ host: Host, _ steps: Int) -> (mainLayouts: Int, memoHits: Int) {
        TranscriptText.resetMeasureStats()
        for _ in 0..<steps {
            host.view.contentOffset.y = max(host.view.contentOffset.y - 100, -host.view.adjustedContentInset.top)
            host.coordinator.controller.readerScrolled(movingUp: true)
            host.view.layoutIfNeeded()
        }
        return TranscriptText.measureStats
    }

    @Test func scrollingWithinThePrefetchedWindowDoesNoMainTextKit() async throws {
        let host = await Self.makeHost()
        let offBefore = TranscriptPremeasurer.offMainLayouts.withLock { $0 }
        TranscriptText.resetMeasureStats()
        host.coordinator.update(rows: Self.rows(count: 3000, salt: "k1"), context: host.context, insets: (0, 0))
        await Self.idle(host)
        _ = await eventually(timeout: .seconds(30)) { host.coordinator.premeasureStats.adopted > 0 }
        #expect(TranscriptPremeasurer.offMainLayouts.withLock { $0 } > offBefore, "open: the worker measured rows")
        #expect(host.coordinator.premeasureStats.adopted > 0)
        let preparedVisibleDescription: String
        #if DEBUG
        let initialVisible = try #require(host.coordinator.visibleRows)
        let rows = host.coordinator.controller.rows
        let driver = Self.driver(host.coordinator)
        // On-screen rows are deliberately measured synchronously. Bring the nearest worker-submitted
        // neighbor into view so the check proves this host prepared a row before it became visible,
        // without inspecting TranscriptText's process-wide LRUs after other suites can evict entries.
        let preparedIndex = try #require(rows.indices
            .filter { driver.adoptedIds.contains(rows[$0].id) && !initialVisible.contains($0) }
            .min { lhs, rhs in
                let distance: (Int) -> Int = { $0 < initialVisible.lowerBound
                    ? initialVisible.lowerBound - $0 : $0 - initialVisible.upperBound }
                return distance(lhs) < distance(rhs)
            })
        let preparedTop = try #require(host.coordinator.rowTop(preparedIndex))
        let targetOffset = max(0, preparedTop - host.view.bounds.height / 3)
        let oldOffset = host.view.contentOffset.y
        TranscriptText.resetMeasureStats()
        host.view.contentOffset.y = targetOffset
        host.coordinator.controller.readerScrolled(movingUp: targetOffset < oldOffset)
        host.view.layoutIfNeeded()
        #expect(TranscriptText.measureStats.mainLayouts == 0,
                "revealing this host's worker-prepared row must not run main-thread TextKit")
        let preparedVisible = host.coordinator.visibleRows?.contains(preparedIndex) == true
        #expect(preparedVisible, "the host's worker-prepared row entered the native visible range")
        #expect(host.coordinator.controller.heights[rows[preparedIndex].id]?.measured == true,
                "the native list laid out the worker-prepared visible row")

        preparedVisibleDescription = String(preparedVisible)
        #else
        preparedVisibleDescription = "not instrumented in release"
        #endif

        // Every row is eligible text/markdown, so the budget for main-thread layouts is zero.
        let rowsBefore = host.coordinator.visibleRows
        let near = Self.scrollSteps(host, 40)
        #expect(host.coordinator.visibleRows != rowsBefore, "the scroll moved the viewport")
        // A jump far outside the window, let the prefetch follow it (worker), then scroll inside the new window.
        let offloadedBeforeJump = host.coordinator.premeasureStats.offloaded
        let target = host.coordinator.rowTop(1500) ?? 0
        host.view.contentOffset.y = target
        host.coordinator.scrollViewDidEndDecelerating(host.view)
        _ = await eventually(timeout: .seconds(30)) { host.coordinator.premeasureStats.offloaded > offloadedBeforeJump }
        await Self.idle(host)
        let jumped = host.coordinator.premeasureStats
        let far = Self.scrollSteps(host, 40)
        print("\nTranscriptPremeasure UIKit scroll (3000 rows): worker-prepared visible row \(preparedVisibleDescription); "
            + "scroll near window: mainLayouts \(near.mainLayouts) memoHits \(near.memoHits); "
            + "after jump: offloaded \(offloadedBeforeJump) -> \(jumped.offloaded), scroll mainLayouts \(far.mainLayouts) memoHits \(far.memoHits); "
            + "premeasureStats \(host.coordinator.premeasureStats)")
        #expect(near.mainLayouts == 0, "scrolling inside the prefetched window ran \(near.mainLayouts) TextKit layouts on main")
        #expect(jumped.offloaded > offloadedBeforeJump, "the prefetch offloads rows around the new position")
        #expect(far.mainLayouts == 0, "scrolling inside the window after a jump ran \(far.mainLayouts) TextKit layouts on main")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
    }

    @Test func ineligibleRowsAreNeverOffloaded() async {
        let host = await Self.makeHost()
        let count = 300
        var rows = Self.rows(count: count, salt: "k2")
        let streamingIndex = count - 1, findIndex = count - 9, controlIndex = count - 13
        let body = String(repeating: "filler words that wrap ", count: 12)
        rows[streamingIndex] = Self.assistant("stream", text: "Streaming reply " + body, streaming: true, at: streamingIndex)
        rows[findIndex] = Self.assistant("find", text: "Find the needle in this reply. " + body, at: findIndex)
        rows[controlIndex] = Self.assistant("control", text: "Plain reply " + body, at: controlIndex)
        var highlight = TranscriptHighlight()
        highlight.query = "needle"
        highlight.rows = ["a-find"]
        host.coordinator.apply(highlight)

        let renderer = host.coordinator.renderer
        #expect(renderer.premeasureBodies(for: rows[streamingIndex]) == nil)
        #expect(renderer.premeasureBodies(for: rows[findIndex]) == nil)
        #expect(renderer.premeasureBodies(for: rows[controlIndex]) != nil)

        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        await Self.idle(host)
        #if DEBUG
        let offloaded = Self.driver(host.coordinator).offloadedIds
        #expect(offloaded.contains("a-control"), "eligible neighbours are offloaded")
        #expect(!offloaded.contains("a-stream"))
        #expect(!offloaded.contains("a-find"))
        #endif
    }

    @Test func streamingUpdatesAndUnchangedHighlightDoNotStallThePrefetch() async {
        let host = await Self.makeHost()
        var rows = Self.rows(count: 1500, salt: "k4")
        rows.append(Self.assistant("live", text: "Streaming", streaming: true, at: rows.count))
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        // updateUIView re-applies the (unchanged) highlight on every flush; the flushes must not cancel the worker.
        for step in 0..<60 {
            rows[rows.count - 1] = Self.assistant("live", text: "Streaming " + String(repeating: "token ", count: step + 1),
                                                  streaming: true, at: rows.count - 1)
            host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
            host.coordinator.apply(TranscriptHighlight())
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Self.idle(host)
        _ = await eventually(timeout: .seconds(30)) { host.coordinator.premeasureStats.adopted > 0 }
        await Self.drained(host)
        let stats = host.coordinator.premeasureStats
        print("\nTranscriptPremeasure UIKit streaming: premeasureStats \(stats)")
        #expect(stats.adopted > 0, "results were adopted while the last row streamed")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
        #if DEBUG
        #expect(!Self.driver(host.coordinator).offloadedIds.contains("a-live"))
        #endif
    }

    @Test func pagingOlderRowsAndTrimmingWhileJobsAreInFlightLeavesNothingInFlight() async {
        let host = await Self.makeHost()
        let rows = Self.rows(count: 3000, salt: "k3")
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        // Catch jobs on the worker, then reshape the list under them.
        _ = await eventually(timeout: .seconds(10)) { Self.driver(host.coordinator).inFlightCount > 0 }
        let sawInFlight = Self.driver(host.coordinator).inFlightCount > 0
        let older = Self.rows(count: 100, salt: "k3old")
        host.coordinator.update(rows: older + rows, context: host.context, insets: (0, 0))
        host.coordinator.update(rows: Array((older + rows).dropFirst(150)), context: host.context, insets: (0, 0))
        await Self.idle(host)
        print("\nTranscriptPremeasure UIKit windowing: jobs were in flight at reshape \(sawInFlight); premeasureStats \(host.coordinator.premeasureStats)")
        #expect(sawInFlight, "the test reshaped the list while jobs were in flight")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
        #expect(Self.driver(host.coordinator).inFlight.isEmpty)
    }

    @Test func theRowWindowCoversTheVisibleRows() async {
        let host = await Self.makeHost()
        host.coordinator.update(rows: Self.rows(count: 400, salt: "k5"), context: host.context, insets: (0, 0))
        await Self.idle(host)
        let visible = try! #require(host.coordinator.visibleRows)
        let window = try! #require(host.coordinator.rowWindow(screens: 1, minimum: 200))
        #expect(window.range.contains(visible.lowerBound) && window.range.contains(visible.upperBound))
        #expect(visible.contains(window.center))
        #expect(window.range.count > visible.count, "the window reaches past the screen")
        #expect(visible.upperBound == 399, "a new list opens at the latest message")
    }

    @Test func widthRoundTripRebuildsUIKitGeometryAndKeepsTheReadingAnchor() async throws {
        let host = await Self.makeHost()
        let window = try #require(host.view.window)
        let rows = Self.rows(count: 240, salt: "width-roundtrip")
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        await Self.idle(host)

        let initialWidth = host.view.bounds.width
        #expect(initialWidth > 40)
        let anchorRow = 100
        guard let anchorTop = host.coordinator.rowTop(anchorRow) else {
            Issue.record("the initial layout did not provide an anchor row")
            return
        }
        host.view.contentOffset.y = anchorTop + 18
        host.coordinator.controller.readerScrolled(movingUp: true)
        guard case let .row(anchorID, _) = host.coordinator.controller.anchor,
              let anchoredIndex = host.coordinator.controller.index[anchorID],
              let initialAnchorTop = host.coordinator.rowTop(anchoredIndex) else {
            Issue.record("the hosted viewport did not establish a row anchor")
            return
        }
        let anchorScreenY = initialAnchorTop - host.view.contentOffset.y

        func resize(to width: CGFloat) async {
            window.frame.size.width = width
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            await Self.idle(host)
            Self.expectConsistentGeometry(host, width: width)
            guard let top = host.coordinator.rowTop(anchoredIndex) else {
                Issue.record("the anchor row lost its content position at width \(width)")
                return
            }
            #expect(abs((top - host.view.contentOffset.y) - anchorScreenY) < 1,
                    "resizing to \(width) moved the anchored row on screen")
            guard case let .row(currentAnchorID, currentOffset) = host.coordinator.controller.anchor else {
                Issue.record("resizing changed the reader's anchor kind")
                return
            }
            #expect(currentAnchorID == anchorID, "resizing changed the reader's anchor row")
            #expect(abs(currentOffset - anchorScreenY) < 0.5, "resizing changed the anchor offset")
        }

        await resize(to: 600)
        await resize(to: initialWidth)
    }

    @Test func scrollToTopDelegateSettlesMeasuredRowsAtTheTop() async {
        let host = await Self.makeHost()
        host.coordinator.update(rows: Self.rows(count: 240, salt: "scroll-to-top"),
                                context: host.context, insets: (0, 0))
        await Self.idle(host)
        #expect((host.coordinator.visibleRows?.lowerBound ?? 0) > 0)
        #expect(host.coordinator.scrollViewShouldScrollToTop(host.view))
        #expect(host.coordinator.isScrolling, "the native delegate marks the scroll-to-top transition active")
        // Model UIKit's completed offset, then invoke its public delegate callback. This is not
        // an automated OS status-bar gesture.
        host.view.contentOffset.y = -host.view.adjustedContentInset.top
        host.coordinator.scrollViewDidScrollToTop(host.view)
        await Self.idle(host)
        #expect(!host.coordinator.isScrolling)
        #expect(host.coordinator.controller.anchor == .top)
        #expect(host.coordinator.visibleRows?.lowerBound == 0)
        Self.expectConsistentGeometry(host, width: host.view.bounds.width)
    }

    static func expectConsistentGeometry(_ host: Host, width: CGFloat) {
        let coordinator = host.coordinator
        let effectiveWidth = coordinator.controller.host?.layoutWidth ?? 0
        #expect(abs(effectiveWidth - width) < 0.5, "the coordinator must use the resized viewport width")

        var expectedTop: CGFloat = 0
        for row in coordinator.controller.rows.indices {
            guard let top = coordinator.rowTop(row),
                  let height = coordinator.controller.heights[coordinator.controller.rows[row].id]?.value else {
                Issue.record("row \(row) is missing cached geometry")
                return
            }
            #expect(abs(top - expectedTop) < 0.5, "row \(row) has an inconsistent cached top")
            expectedTop = top + height
            if row + 1 < coordinator.controller.rows.count { expectedTop += TranscriptLayout.rowSpacing }
        }
        #expect(abs(host.view.contentSize.height - expectedTop) < 0.5,
                "UICollectionView content size should match the coordinator's row geometry")

        guard let visible = coordinator.visibleRows else {
            Issue.record("the hosted collection view has no visible rows")
            return
        }
        for row in visible {
            let item = coordinator.controller.rows[row]
            guard let height = coordinator.controller.heights[item.id],
                  let attributes = host.view.collectionViewLayout.layoutAttributesForItem(
                    at: IndexPath(item: row, section: 0)) else {
                Issue.record("visible row \(row) is missing its measured layout")
                continue
            }
            #expect(height.isCurrent(at: width), "visible row \(row) was not measured at the resized width")
            guard let top = coordinator.rowTop(row) else { continue }
            #expect(abs(attributes.frame.minY - top) < 0.5)
            #expect(abs(attributes.frame.width - width) < 0.5)
            #expect(abs(attributes.frame.height - height.value) < 0.5)
        }
    }
}
#endif
