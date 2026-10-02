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
        var reactionsEnabled: Bool { true }
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
        func isReadingAloud(_ messageId: String) -> Bool { false }
        func canReadAloud(_ messageId: String) -> Bool { true }
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
        let builder = TranscriptLayoutBuilder(context: context, settings: .current(for: context))

        func footer(_ width: CGFloat) throws -> (TranscriptRowLayout, TranscriptRowLayout.Placed, TranscriptFooterView) {
            let layout = builder.layout(row, width: width)
            let placed = try #require(layout.parts.first { if case .footer = $0.part { true } else { false } })
            let view = TranscriptFooterView(frame: placed.frame)
            view.configure(placed.part, row: layout, actions: actions)
            view.layoutContent()
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

        #expect(metadataWidth <= compactPart.frame.width,
                "full model and timestamp need \(metadataWidth)pt, compact footer has \(compactPart.frame.width)pt")
        #expect(compactPart.frame.height >= actionBottom + TranscriptMetrics.footerSpacing + captionHeight,
                "footer needs a caption row below its visible controls; footer height \(compactPart.frame.height), controls end \(actionBottom)")
        #expect(compactLayout.parts.contains { if case .footer = $0.part { true } else { false } })

        let (_, widePart, wideView) = try footer(600)
        let wideButtons = wideView.subviews.compactMap { $0 as? TranscriptLabelButton }.filter { !$0.isHidden }
        let wideDetailsX = (wideButtons.map(\.frame.maxX).max() ?? 0) + 10
        #expect(widePart.frame.height == captionHeight, "wide footer keeps its existing single-line height")
        #expect(widePart.frame.width - wideDetailsX >= metadataWidth,
                "wide footer keeps model and timestamp after the actions")
    }

    private func footerPart(_ part: TranscriptPart) -> TranscriptPart.Footer {
        guard case let .footer(footer) = part else { fatalError("expected a footer part") }
        return footer
    }
}
