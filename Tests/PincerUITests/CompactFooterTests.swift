import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// The compact transcript footer must leave the metadata a real line below its message actions.
@MainActor
@Suite("Compact transcript footer", .serialized)
struct CompactFooterTests {
    @MainActor
    final class Actions: TranscriptRowActions {
        var readingAloud = false
        var readable = true
        var reactionsEnabled = true
        var branchEntries: [TranscriptBranchEntry] { [] }
        var liveAvatar: TranscriptLiveAvatar? { nil }

        func setExpanded(_ key: String, _ expanded: Bool, row: String) {}
        func openRun(_ sessionKey: String) {}
        func openChat(_ sessionKey: String) {}
        func openMCPServer(_ name: String) {}
        func preview(_ ref: ImageRef) {}
        func previewHTML(_ html: String) {}
        func open(_ url: URL) {}
        func loadImage(_ ref: ImageRef) {}
        func loadFilePreview(_ file: FileRef) {}
        func previewHTML(_ file: FileRef) async -> Bool { false }
        func saveFile(_ file: FileRef) async -> Bool { false }
        func quickLook(_ file: FileRef) async -> Bool { false }
        func reply(to messageId: String) {}
        func canBranch(from messageId: String) -> Bool { false }
        func canEdit(_ messageId: String) -> Bool { false }
        func canRegenerate(_ messageId: String) -> Bool { false }
        func branch(from messageId: String) {}
        func edit(_ messageId: String) {}
        func regenerate(_ messageId: String) {}
        func copyLink(to messageId: String) {}
        func toggleBookmark(_ messageId: String) {}
        func isBookmarked(_ messageId: String) -> Bool { false }
        func readAloud(_ messageId: String) {}
        func isReadingAloud(_ messageId: String) -> Bool { self.readingAloud }
        func canReadAloud(_ messageId: String) -> Bool { self.readable }
        func toggleReaction(_ emoji: String, on messageId: String) {}
        func pickReaction(for messageId: String, from view: PView, rect: CGRect) {}
        func stepBranch(_ offset: Int) {}
        func switchBranch(to leafEntryId: String) {}
        func showOriginal(_ messageId: String) {}
        func retrySend(_ id: String) {}
        func sendNow(_ id: String) {}
        func deleteSend(_ id: String) {}
    }

    @Test func narrowAssistantFooterReservesAReadableMetadataLine() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let profile = GatewayProfile(name: "Footer", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:footer:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "footer", name: "Footer"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in })
        let actions = Actions()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var turn = AssistantTurn(id: "compact-footer-turn", timestamp: stamp)
        turn.text = ["A short answer that can be read aloud."]
        turn.textTimestamps = [stamp]
        turn.textModelNames = ["claude-opus-4-8"]
        turn.textIds = ["compact-footer-message"]
        let row = TranscriptRow.entry(.assistant(turn))
        var settings = TranscriptSettings.current(for: context)
        settings.reactionsEnabled = true
        let builder = TranscriptLayoutBuilder(context: context, settings: settings)

        func footer(_ width: CGFloat) throws -> (TranscriptRowLayout, TranscriptRowLayout.Placed, TranscriptFooterView) {
            let layout = builder.layout(row, width: width)
            let placed = try #require(layout.parts.first { if case .footer = $0.part { true } else { false } })
            let view = TranscriptFooterView(frame: placed.frame)
            let textMeasuresBeforeView = TranscriptText.measureStats
            view.configure(placed.part, row: layout, actions: actions)
            view.layoutContent()
            let textMeasuresAfterView = TranscriptText.measureStats
            #expect(textMeasuresAfterView.mainLayouts == textMeasuresBeforeView.mainLayouts,
                    "footer arrangement must not add main-thread TextKit layouts")
            #expect(textMeasuresAfterView.memoHits == textMeasuresBeforeView.memoHits,
                    "footer arrangement must not request extra TextKit measurements")
            return (layout, placed, view)
        }

        let (compactLayout, compactPart, compactView) = try footer(350)
        let compactDetails = footerPart(compactPart.part).details
        #expect(compactDetails.contains("claude-opus-4-8"))
        #expect(compactDetails.contains(stamp.messageDetailTimestamp))
        let caption = TranscriptStyle.shared.caption
        let metadataWidth = singleLine(compactDetails, caption, TranscriptColors.tertiary).lineWidth
        let captionHeight = max(TranscriptStyle.lineHeight(caption), 16)
        let visibleButtons = compactView.subviews.compactMap { $0 as? TranscriptLabelButton }.filter { !$0.isHidden }
        let labels = Set(visibleButtons.map(\.accessibilityText))
        #expect(labels.contains("Copy message"))
        #expect(labels.contains("Reply"))
        #expect(labels.contains("Read Aloud"))
        #expect(labels.contains("Add Reaction"))
        let actionBottom = visibleButtons.map(\.frame.maxY).max() ?? 0

        let compactDetailsFrame = compactView.detailsDrawFrame
        #expect(compactDetailsFrame.minX == 0)
        #expect(compactDetailsFrame.width == compactPart.frame.width,
                "compact metadata spans the whole content width instead of the remaining inline sliver")
        #expect(compactDetailsFrame.minY >= actionBottom,
                "metadata must start below every visible action row; metadata starts at \(compactDetailsFrame.minY), controls end \(actionBottom)")
        #expect(compactDetailsFrame.height >= captionHeight * 2,
                "compact metadata reserves two caption lines for a wrapped model and timestamp")
        #expect(compactPart.frame.height >= compactDetailsFrame.maxY,
                "metadata draw frame must be inside its measured footer frame")
        #expect(compactLayout.parts.contains { if case .footer = $0.part { true } else { false } })

        actions.readingAloud = true
        compactView.configure(compactPart.part, row: compactLayout, actions: actions)
        compactView.layoutContent()
        let stopButton = try #require(compactView.subviews.compactMap { $0 as? TranscriptLabelButton }
            .first { $0.accessibilityText == "Stop Reading Aloud" })
        #expect(stopButton.frame.maxX <= compactPart.frame.width)
        #expect(compactView.detailsDrawFrame == compactDetailsFrame,
                "Listen-to-Stop state changes must stay inside the reserved compact control rows")
        actions.readingAloud = false
        compactView.configure(compactPart.part, row: compactLayout, actions: actions)
        compactView.layoutContent()
        #expect(compactView.detailsDrawFrame == compactDetailsFrame)

        let (_, widePart, wideView) = try footer(600)
        let wideButtons = wideView.subviews.compactMap { $0 as? TranscriptLabelButton }.filter { !$0.isHidden }
        let wideDetailsX = (wideButtons.map(\.frame.maxX).max() ?? 0) + 10
        #expect(widePart.frame.height == captionHeight, "wide footer keeps its existing single-line height")
        #expect(widePart.frame.width - wideDetailsX >= metadataWidth,
                "wide footer keeps model and timestamp after the actions")
        #expect(wideView.detailsDrawFrame.height == TranscriptStyle.lineHeight(caption),
                "wide details remain on one actual caption-height line")
        #expect(wideView.detailsDrawFrame.width >= metadataWidth,
                "wide details draw frame preserves its existing one-line metadata")

        // Reuse the same native footer view across the width-class boundary: the wide path remains
        // one line, and returning to compact restores the full-width two-line metadata frame.
        let wideLayout = builder.layout(row, width: 600)
        let widePlaced = try #require(wideLayout.parts.first { if case .footer = $0.part { true } else { false } })
        compactView.frame = widePlaced.frame
        compactView.configure(widePlaced.part, row: wideLayout, actions: actions)
        compactView.layoutContent()
        #expect(compactView.detailsDrawFrame.height == TranscriptStyle.lineHeight(caption))
        compactView.frame = compactPart.frame
        compactView.configure(compactPart.part, row: compactLayout, actions: actions)
        compactView.layoutContent()
        #expect(compactView.detailsDrawFrame == compactDetailsFrame)
    }

    @Test func compactFooterUsesOnePackedRowAtTypicalPhoneContentWidths() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let profile = GatewayProfile(name: "Footer", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:footer:single-action-row"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "footer", name: "Footer"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in })
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var turn = AssistantTurn(id: "compact-footer-single-action-row", timestamp: stamp)
        turn.text = ["A reply with model and time metadata."]
        turn.textTimestamps = [stamp]
        turn.textModelNames = ["claude-opus-4-8"]
        turn.textIds = ["compact-footer-single-action-row-message"]

        var settings = TranscriptSettings.current(for: context)
        settings.reactionsEnabled = false
        var actions = Actions()
        actions.reactionsEnabled = false
        let builder = TranscriptLayoutBuilder(context: context, settings: settings)
        for (rowWidth, expectedContentWidth) in [(356.0, 280.0), (406.0, 330.0)] {
            let layout = builder.layout(.entry(.assistant(turn)), width: rowWidth)
            let placed = try #require(layout.parts.first { if case .footer = $0.part { true } else { false } })
            let footer = footerPart(placed.part)
            let view = TranscriptFooterView(frame: placed.frame)
            view.configure(placed.part, row: layout, actions: actions)
            view.layoutContent()

            let visibleButtons = view.subviews.compactMap { $0 as? TranscriptLabelButton }.filter { !$0.isHidden }
            let actualActionRows = Set(visibleButtons.map { Int($0.frame.midY / footer.actionRowHeight) })
            #expect(abs(placed.frame.width - expectedContentWidth) < 1,
                    "fixture exercises the intended phone content width")
            #expect(actualActionRows.count == 1, "Copy, Reply and Listen fit on one row at \(expectedContentWidth)pt")
            #expect(footer.controlHeight == footer.actionRowHeight,
                    "the row model reserves only the one action row the view uses")
            #expect(footer.detailsFrame.minY == footer.controlHeight + 4,
                    "metadata starts immediately after that packed action row")
            #expect(placed.frame.height == footer.controlHeight + 4 + footer.detailsFrame.height,
                    "the row's measured height matches its packed action and metadata geometry")
        }
    }

    @Test func compactFooterReservesOnlyItsActualMetadataLines() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let profile = GatewayProfile(name: "Footer", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:footer:timestamp-only"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "footer", name: "Footer"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in })
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var turn = AssistantTurn(id: "compact-footer-timestamp-only", timestamp: stamp)
        turn.text = ["A reply without recorded model metadata."]
        turn.textTimestamps = [stamp]
        turn.textIds = ["compact-footer-timestamp-only-message"]

        var settings = TranscriptSettings.current(for: context)
        settings.reactionsEnabled = false
        let layout = TranscriptLayoutBuilder(context: context, settings: settings)
            .layout(.entry(.assistant(turn)), width: 420)
        let placed = try #require(layout.parts.first { if case .footer = $0.part { true } else { false } })
        let footer = footerPart(placed.part)
        let view = TranscriptFooterView(frame: placed.frame)
        var actions = Actions()
        actions.reactionsEnabled = false
        view.configure(placed.part, row: layout, actions: actions)
        view.layoutContent()

        let captionHeight = max(TranscriptStyle.lineHeight(TranscriptStyle.shared.caption), 16)
        #expect(footer.detailLines.count == 1)
        #expect(Set(view.subviews.compactMap { $0 as? TranscriptLabelButton }.filter { !$0.isHidden }
            .map { Int($0.frame.midY / footer.actionRowHeight) }).count == 1,
                "the timestamp-only fixture also packs its visible actions into one row")
        #expect(view.detailsDrawFrame.height == captionHeight,
                "a timestamp-only footer draws one metadata line")
        #expect(placed.frame.height == footer.controlHeight + 4 + captionHeight,
                "the row height includes only its one metadata line")
    }

    @Test func compactBranchAndBookmarkKeepTheirOwnControlRow() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Footer", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:footer:branch"
        let chat = gateway.chat(for: key)
        var item = ChatItem(id: "compact-footer-user", role: .user, blocks: [.text("A branchable message")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let messageID = "compact-footer-branch-message"
        item.transcriptId = messageID
        chat.items = [item]
        chat.branches = [SessionBranch(leafEntryId: "first", headline: "first", messageCount: 1, active: false),
                         SessionBranch(leafEntryId: "second", headline: "second", messageCount: 1, active: true)]
        let bookmarks = BookmarkStore.shared(gatewayId: gateway.id)
        defer { bookmarks.removeAll() }
        bookmarks.add(Bookmark(sessionKey: key, messageId: messageID, preview: item.plainText))
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "footer", name: "Footer"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        var settings = TranscriptSettings.current(for: context)
        settings.reactionsEnabled = true
        let layout = TranscriptLayoutBuilder(context: context, settings: settings)
            .layout(.entry(.user(item)), width: 260)
        let placed = try #require(layout.parts.first { if case .footer = $0.part { true } else { false } })
        let footer = footerPart(placed.part)
        #expect(footer.branch?.count == 2)
        #expect(footer.isBookmarked)
        #if os(iOS)
        let branchTargetHeight: CGFloat = 44
        #else
        let branchTargetHeight: CGFloat = 28
        #endif
        #expect(footer.controlHeight >= branchTargetHeight + 4 + 2 * footer.actionRowHeight)

        let view = TranscriptFooterView(frame: placed.frame)
        let userActions = Actions()
        userActions.readable = false
        userActions.reactionsEnabled = settings.reactionsEnabled
        view.configure(placed.part, row: layout, actions: userActions)
        view.layoutContent()
        let visible = view.subviews.compactMap { $0 as? TranscriptLabelButton }.filter { !$0.isHidden }
        #expect(Set(visible.map(\.accessibilityText)).isSuperset(of: ["Previous branch", "Branch 2 of 2", "Next branch",
                                                                     "Remove Bookmark", "Copy message"]))
        #expect(view.detailsDrawFrame.minY >= (visible.map(\.frame.maxY).max() ?? 0))

        let branchLabels: Set<String> = ["Previous branch", "Branch 2 of 2", "Next branch"]
        let actionButtons = visible.filter { !branchLabels.contains($0.accessibilityText) }
        let actionOrigin = footer.branchRowHeight + 4
        let actionRows = Set(actionButtons.map { Int(($0.frame.midY - actionOrigin) / footer.actionRowHeight) })
        #expect(actionRows.count > 1, "the branch and bookmark controls force a real wrapped action row")
        let effectiveHits = actionButtons.map {
            $0.frame.insetBy(dx: -$0.hitOutset.width, dy: -$0.hitOutset.height)
        }
        for hit in effectiveHits {
            #expect(view.bounds.contains(hit), "effective action hit regions remain inside the footer")
            #expect(hit.minY >= actionOrigin)
            #expect(hit.maxY <= footer.controlHeight)
            #expect(hit.maxY <= view.detailsDrawFrame.minY)
        }
        #if os(iOS)
        for hit in effectiveHits {
            #expect(hit.width >= 44, "compact iOS actions retain a 44pt touch width")
            #expect(hit.height >= 44, "compact iOS actions retain a 44pt touch height")
        }
        #endif
        for first in effectiveHits.indices {
            for second in effectiveHits.indices where second > first {
                #expect(!effectiveHits[first].intersects(effectiveHits[second]),
                        "wrapped action hit targets must not overlap")
            }
        }
    }

    @Test func listenReservationUsesPerMessageAssistantEligibility() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Footer", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:footer:mixed-error"
        let chat = gateway.chat(for: key)
        var normal = ChatItem(id: "footer-normal-assistant", role: .assistant,
                              blocks: [.text("A normal assistant message")], timestamp: Date())
        normal.transcriptId = "footer-normal-message"
        var failed = ChatItem(id: "footer-error-assistant", role: .assistant,
                              blocks: [.text("A failed assistant message")], timestamp: Date())
        failed.transcriptId = "footer-error-message"
        failed.isError = true
        chat.items = [normal, failed]

        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "footer", name: "Footer"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let turn = try #require(TranscriptBuilder.build([normal, failed]).compactMap { entry -> AssistantTurn? in
            if case let .assistant(turn) = entry { turn } else { nil }
        }.first)
        let layout = TranscriptLayoutBuilder(context: context, settings: .current(for: context))
            .layout(.entry(.assistant(turn)), width: 350)
        let footers = layout.parts.compactMap { placed -> TranscriptPart.Footer? in
            if case let .footer(footer) = placed.part { footer } else { nil }
        }
        #expect(footers.count == 2)
        #expect(footers[0].actionFrames[.listen] != nil,
                "a normal message keeps its Listen slot when a later message makes the aggregate turn an error")
        #expect(footers[1].actionFrames[.listen] == nil,
                "an errored message does not reserve Listen")
    }

    private func footerPart(_ part: TranscriptPart) -> TranscriptPart.Footer {
        guard case let .footer(footer) = part else { fatalError("expected a footer part") }
        return footer
    }
}

#if os(iOS)
// The simulator CI lane explicitly selects this existing suite. Keep the compact footer's
// iOS hit-target regressions on that lane without requiring a workflow change.
extension TranscriptUIKitLayoutTests {
    @Test func compactFooterKeepsMetadataBelowActions() throws {
        try CompactFooterTests().narrowAssistantFooterReservesAReadableMetadataLine()
    }

    @Test func compactFooterKeepsBranchAndBookmarkTargetsSeparate() throws {
        try CompactFooterTests().compactBranchAndBookmarkKeepTheirOwnControlRow()
    }

    @Test func compactFooterReservesOnlyItsActualMetadataLines() throws {
        try CompactFooterTests().compactFooterReservesOnlyItsActualMetadataLines()
    }

    @Test func messageFooterGapTracksPackedActionRows() throws {
        try CompactFooterTests().compactFooterUsesOnePackedRowAtTypicalPhoneContentWidths()
    }

    @Test func compactFooterListenReservationUsesPerMessageEligibility() throws {
        try CompactFooterTests().listenReservationUsesPerMessageAssistantEligibility()
    }
}

#endif
