import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Message footers

extension TranscriptLayoutBuilder {
    func messageFooter(_ turn: AssistantTurn, message index: Int, layout: TranscriptRowLayout,
                                   into stack: inout Stack)
    {
        let time = turn.textTimestamps.indices.contains(index) ? turn.textTimestamps[index] : turn.timestamp
        let messageId = Self.messageId(turn, index)
        // This is a cheap packing candidate, not the final Read Aloud decision: the footer view
        // still checks SpeechText once when configured. Avoid parsing the whole body a second time
        // on the row-layout path merely to remove a possible empty slot from unusual markup.
        let canListen: Bool
        if let messageId, let item = self.context.chat?.message(withId: messageId) {
            canListen = item.role == .assistant && !item.isPending && !item.isError && !turn.text[index].isEmpty
        } else {
            canListen = !turn.isStreaming && !turn.isError && messageId != nil && !turn.text[index].isEmpty
        }
        self.footer(key: "\(turn.id):\(index)", copy: turn.text[index], time: time ?? turn.timestamp,
                    model: self.model(of: turn, message: index), messageId: messageId, canListen: canListen,
                    layout: layout,
                    into: &stack)
    }

    /// Transcript id of one message of a turn, when replies and reactions can target it.
    static func messageId(_ turn: AssistantTurn, _ index: Int) -> String? {
        guard !turn.isStreaming, turn.textIds.indices.contains(index) else { return nil }
        return turn.textIds[index]
    }

    /// Transcript id of one message of a turn whose reactions show. Committed messages keep their
    /// chips while the rest of the turn streams, though Reply and React wait for it to finish.
    static func chipId(_ turn: AssistantTurn, _ index: Int) -> String? {
        turn.textIds.indices.contains(index) ? turn.textIds[index] : nil
    }

    /// Model that wrote a message, falling back to the turn's when the message didn't record one.
    fileprivate func model(of turn: AssistantTurn, message index: Int) -> String? {
        // Someone else's model, which this chat doesn't know.
        guard turn.sender == nil else { return nil }
        let own = turn.textModelNames.indices.contains(index) ? turn.textModelNames[index] : nil
        return own ?? turn.modelName
    }

    func footer(key: String, copy text: String, time: Date?, model: String?, messageId: String?,
                            canListen: Bool = false,
                            layout: TranscriptRowLayout, into stack: inout Stack)
    {
        let bookmarked = messageId.map { layout.decoration.bookmarks.contains($0) } ?? false
        let timeDetail = time?.messageDetailTimestamp
        let detailLines = [model, timeDetail].compactMap(\.self)
        let details = detailLines.joined(separator: " · ")
        let lineHeight = TranscriptStyle.lineHeight(self.style.caption)
        let captionHeight = max(lineHeight, 16)
        let compact = stack.width < 430
        let branch = layout.decoration.branch
        let actionRowHeight: CGFloat
        #if os(iOS)
        actionRowHeight = 44
        #else
        // Bookmark's existing 8pt vertical hit outset adds 16pt to its 16pt caption-height frame.
        actionRowHeight = max(captionHeight, 32)
        #endif
        let controlHeight: CGFloat
        let detailsFrame: CGRect
        let height: CGFloat
        let actionFrames: [TranscriptPart.Footer.Action: CGRect]
        let footerActionRowHeight: CGFloat
        if compact {
            var actions: [TranscriptPart.Footer.Action] = []
            if branch != nil { actions.append(.branch) }
            if bookmarked { actions.append(.bookmark) }
            if !text.isEmpty { actions.append(.copy) }
            if messageId != nil { actions.append(.reply) }
            if canListen { actions.append(.listen) }
            if messageId != nil, self.settings.reactionsEnabled { actions.append(.react) }
            let branchWidth = branch.map { TranscriptFooterView.branchSlotWidths(label: $0.label).reduce(0, +) } ?? 0
            let packed = CompactFooterPacking.pack(width: stack.width, actions: actions, rowHeight: actionRowHeight,
                                                   branchWidth: branchWidth)
            actionFrames = packed.frames
            footerActionRowHeight = packed.rowHeight
            controlHeight = CGFloat(packed.rowCount) * footerActionRowHeight
            let detailsY = controlHeight + (detailLines.isEmpty ? 0 : 4)
            let detailsHeight = CGFloat(detailLines.count) * captionHeight
            detailsFrame = CGRect(x: 0, y: detailsY, width: stack.width, height: detailsHeight)
            height = detailsFrame.maxY
        } else {
            controlHeight = 0
            actionFrames = [:]
            footerActionRowHeight = actionRowHeight
            detailsFrame = .zero // The wide single-line frame follows the visible buttons in the view.
            height = captionHeight
        }
        stack.add(.footer(.init(key: key, copyText: text, details: details, compact: compact,
                                actionRowHeight: footerActionRowHeight,
                                controlHeight: controlHeight, detailsFrame: detailsFrame, detailLines: detailLines,
                                actionFrames: actionFrames,
                                messageId: messageId, isBookmarked: bookmarked, branch: branch)),
                  height: height,
                  spacing: TranscriptMetrics.footerSpacing)
    }
}
