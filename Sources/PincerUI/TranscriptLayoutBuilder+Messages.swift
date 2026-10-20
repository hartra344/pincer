import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension TranscriptLayoutBuilder {
    // MARK: Rows

    func user(_ item: ChatItem, into layout: inout TranscriptRowLayout) {
        let author = item.senderName(you: Owner.displayName, agent: self.context.agent.name,
                                     agents: self.context.gateway.agents)
        let header = TranscriptPart.Header(name: author, badge: item.via.map { L("via \($0)") },
                                           time: item.timestamp?.chatTimestamp, isPending: item.isAwaitingDelivery)
        let text = item.plainText
        let messageId = item.isReplyable ? item.transcriptId : nil
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: layout.width)
        let quote = layout.decoration.quote.map {
            self.replyQuote($0, isLocating: layout.decoration.isLocating, width: min(contentWidth, TranscriptMetrics.maxCardWidth))
        }
        let sendStatus = Self.sendStatus(item)
        layout.sendStatus = sendStatus
        layout.alpha = item.isPending && sendStatus?.isFailed != true ? 0.7 : 1
        layout.copyItems = [.init(title: L("Copy Text"), text: text)]
        let attachments = item.blocks.filter { if case .image = $0 { true } else if case .file = $0 { true } else { false } }.count
        layout.accessibilityLabel = AccessibilityText.messageRow(
            role: .user, userAuthor: item.channelSenderName, text: text, timestamp: header.time, attachmentCount: attachments,
            isPending: item.isPending && sendStatus == nil, isBookmarked: !layout.decoration.bookmarks.isEmpty,
            via: item.via, summaryLimit: 0)
        if let sendStatus { layout.accessibilityLabel += ". \(sendStatus.spoken)" }
        if let quote {
            layout.accessibilityLabel = L("In reply to \(quote.sender ?? L("a message")): \(quote.preview.string). ") + layout.accessibilityLabel
        }
        self.scaffold(avatar: .init(text: Owner.initials, emoji: nil, color: TranscriptColors.ownerAvatar),
                      header: header, into: &layout) { stack, layout in
            if let quote {
                stack.add(.replyQuote(quote), height: Self.quoteHeight(quote), width: min(stack.width, TranscriptMetrics.maxCardWidth))
            }
            if !text.isEmpty { self.markdown(text, tone: .primary, section: .message(0), into: &stack, layout: &layout) }
            let images = item.blocks.compactMap { block -> ImageRef? in
                if case let .image(ref) = block { return ref }
                return nil
            }
            self.images(images, into: &stack, layout: &layout)
            for block in item.blocks {
                if case let .file(file) = block { self.file(file, into: &stack, layout: &layout) }
            }
            if let messageId { self.reactions(on: messageId, into: &stack, layout: layout) }
            if let sendStatus {
                stack.add(.sendStatus(sendStatus), height: max(TranscriptStyle.lineHeight(self.style.caption), 16),
                          spacing: TranscriptMetrics.footerSpacing)
            }
            if !item.isPending, !text.isEmpty || messageId != nil {
                self.footer(key: "\(item.id):0", copy: text, time: item.timestamp, model: nil, messageId: messageId,
                            layout: layout, into: &stack)
            }
            if let messageId {
                layout.messages.append(.init(id: messageId, minY: TranscriptMetrics.verticalPadding, maxY: stack.y))
            }
        }
    }

    /// A large upload waiting for a cheaper network; Send Now uploads it anyway.
    static func heldStatus(id: String, hold: OutboxHold, bytes: Int?) -> TranscriptPart.SendStatus {
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? L("large")
        let text: String, detail: String, spoken: String
        switch hold {
        case .constrained:
            text = L("Waiting — Low Data Mode")
            detail = L("This is a large upload (\(size)), so it’s waiting while Low Data Mode is on. Send Now uploads it anyway.")
            spoken = L("Not sent yet. It’s a large upload, \(size), waiting while Low Data Mode is on.")
        case .expensive:
            #if os(macOS)
            text = L("Waiting — Personal Hotspot")
            detail = L("This is a large upload (\(size)), so it’s waiting until you’re off Personal Hotspot. Send Now uploads it anyway.")
            spoken = L("Not sent yet. It’s a large upload, \(size), waiting until you’re off Personal Hotspot.")
            #else
            text = L("Waiting for Wi‑Fi")
            detail = L("This is a large upload (\(size)), so it’s waiting for Wi‑Fi to save cellular data. Send Now uploads it anyway.")
            spoken = L("Not sent yet. It’s a large upload, \(size), waiting for Wi‑Fi.")
            #endif
        }
        return .init(kind: .held, id: id, text: text, isFailed: false, canRetry: false, canDelete: true, canSendNow: true,
                     detail: detail, spoken: spoken)
    }

    /// The status line of a queued or failed message; nil while sending and once accepted.
    static func sendStatus(_ item: ChatItem) -> TranscriptPart.SendStatus? {
        guard item.isPending, let state = item.outboxState, let id = item.idempotencyKey else { return nil }
        switch state {
        case .queued:
            if let hold = item.outboxHold { return Self.heldStatus(id: id, hold: hold, bytes: item.outboxUploadBytes) }
            return .init(kind: .queued, id: id, text: L("Queued"), isFailed: false, canRetry: false, canDelete: true, spoken: L("Not sent yet, queued."))
        case .sending:
            return .init(kind: .sending, id: id, text: L("Sending…"), isFailed: false, canRetry: false, canDelete: false, spoken: L("Sending."))
        case let .failed(failure):
            let prefix = "Couldn’t send: "
            let reason = failure.message.hasPrefix(prefix) ? String(failure.message.dropFirst(prefix.count)) : failure.message
            let sentence = reason.hasSuffix(".") ? reason : reason + "."
            return .init(kind: .failed, id: id, text: reason.isEmpty ? L("Failed") : L("Failed — \(reason)"), isFailed: true,
                         canRetry: failure.retryable, canDelete: true, detail: failure.message,
                         spoken: reason.isEmpty ? L("Failed to send.") : L("Failed to send: \(sentence)"))
        }
    }

    func assistant(_ turn: AssistantTurn, into layout: inout TranscriptRowLayout) {
        let agent = self.context.agent
        let from = turn.sender.map { self.sender($0) }
        layout.sourceChat = from?.source
        var header = TranscriptPart.Header(name: from?.name ?? agent.name, badge: from?.marker,
                                           time: turn.timestamp?.chatTimestamp, isPending: false)
        header.link = from?.source
        let thinking = turn.thinking.joined(separator: "\n\n")
        let body = turn.body
        layout.copyItems = [.init(title: L("Copy Reply"), text: body)]
        if !thinking.isEmpty { layout.copyItems.append(.init(title: L("Copy Thinking"), text: thinking)) }
        let accessibilityAuthor = turn.sender?.accessibilityAuthor(
            agents: self.context.gateway.agents, receivingAgentId: agent.id, resolvedName: header.name) ?? header.name
        layout.accessibilityLabel = AccessibilityText.messageRow(
            role: .assistant, author: accessibilityAuthor,
            text: turn.isStreaming ? AccessibilityText.streamingExcerpt(body) : body, timestamp: header.time,
            toolCount: turn.tools.count, attachmentCount: turn.images.count + turn.files.count,
            isStreaming: turn.isStreaming, isError: turn.isError, isBookmarked: !layout.decoration.bookmarks.isEmpty,
            summaryLimit: 0)
        var firstQuote: TranscriptPart.ReplyQuote?
        for index in turn.textIds.indices where firstQuote == nil { firstQuote = self.agentQuote(turn, index, layout: layout) }
        if let quote = firstQuote {
            layout.accessibilityLabel = L("In reply to \(quote.sender ?? L("a message")): \(quote.preview.string). ") + layout.accessibilityLabel
        }
        let pages = Self.pageCards(turn.tools)
        for page in pages {
            let suffix = L("Web page: \(page.displayTitle), \(page.host)")
            layout.accessibilityLabel = layout.accessibilityLabel.isEmpty ? suffix : layout.accessibilityLabel + ". " + suffix
        }
        let reasoning = self.settings.reasoningOff ? "" : thinking
        let hasSteps = !reasoning.isEmpty || !turn.tools.isEmpty
        let hasReply = !turn.text.isEmpty || !turn.images.isEmpty || !turn.files.isEmpty
        let steps: ThinkingSteps = switch self.settings.thinking {
        case _ where !hasSteps: .hidden
        // Find's selected match is in the steps, which this setting would hide: show them for now.
        case _ where !turn.isStreaming && self.highlight.revealsSteps(of: layout.id): .grouped
        case .none: .hidden
        case _ where turn.isStreaming: .live
        case .all: .grouped
        // A finished turn with nothing else to show keeps its steps, folded, so it isn't blank.
        case .live: hasReply ? .hidden : .grouped
        }
        let avatar = from?.avatar ?? TranscriptPart.Avatar(
            text: String(agent.name.prefix(1)).uppercased(), emoji: agent.emoji,
            color: TranscriptColors.agentAvatar, creature: self.settings.avatarStyle,
            state: turn.isStreaming ? .streaming : .idle, isAgent: true, seed: agent.id)
        self.scaffold(avatar: avatar,
                      header: header, into: &layout) { stack, layout in
            switch steps {
            case .hidden:
                break
            case .live:
                if !reasoning.isEmpty { self.thinking(reasoning, turn: turn, into: &stack, layout: &layout) }
                self.tools(turn.tools, into: &stack, layout: &layout)
            case .grouped:
                self.thinkingGroup(reasoning, turn: turn, into: &stack, layout: &layout)
            }
            // One stable spot for the page cards: after the steps, before the reply text.
            for page in pages { self.pageCard(page, turn: turn, into: &stack, layout: &layout) }
            // Each message gets its own footer, which with the gap after it keeps back-to-back
            // messages apart. The last footer goes under the turn's images and files.
            let showFooters = !turn.isStreaming
            let last = turn.text.count - 1
            var start: CGFloat = 0
            for (index, message) in turn.text.enumerated() {
                if index > 0 { stack.y += TranscriptMetrics.messageSpacing - TranscriptMetrics.blockSpacing }
                start = stack.isEmpty ? stack.y : stack.y + TranscriptMetrics.blockSpacing
                if let quote = self.agentQuote(turn, index, layout: layout) {
                    stack.add(.replyQuote(quote), height: Self.quoteHeight(quote), width: min(stack.width, TranscriptMetrics.maxCardWidth))
                }
                self.markdown(message, tone: turn.isError ? .error : .primary, section: .message(index), live: turn.isStreaming,
                              into: &stack, layout: &layout)
                guard index < last else { continue }
                let id = Self.messageId(turn, index)
                if let chipId = Self.chipId(turn, index) {
                    self.reactions(on: chipId, canAdd: id != nil, into: &stack, layout: layout)
                }
                if showFooters { self.messageFooter(turn, message: index, layout: layout, into: &stack) }
                if let id {
                    let opening = self.openingExcerptSource(message, messageCount: turn.text.count)
                    layout.messages.append(.init(id: id, minY: start, maxY: stack.y, openingExcerptSource: opening))
                }
            }
            self.images(turn.images, into: &stack, layout: &layout)
            for file in turn.files { self.file(file, into: &stack, layout: &layout) }
            if !turn.text.isEmpty {
                let id = Self.messageId(turn, last)
                if let chipId = Self.chipId(turn, last) {
                    self.reactions(on: chipId, canAdd: id != nil, into: &stack, layout: layout)
                }
                if showFooters { self.messageFooter(turn, message: last, layout: layout, into: &stack) }
                if let id {
                    let opening = self.openingExcerptSource(turn.text[last], messageCount: turn.text.count)
                    layout.messages.append(.init(id: id, minY: start, maxY: stack.y, openingExcerptSource: opening))
                }
            }
            let showsActivity = steps == .live && (!reasoning.isEmpty || turn.tools.contains(where: \.isRunning))
            if turn.isStreaming, turn.text.isEmpty, !showsActivity {
                stack.add(.typing, height: 14, width: 26)
            }
        }
    }

    /// Captures at most the fixed prefix on main and immediately queues plain-text normalization
    /// off-main. Only grouped messages need per-part labels.
    private func openingExcerptSource(_ message: String, messageCount: Int) -> MessagePartExcerptSource? {
        guard messageCount > 1 else { return nil }
        let source = MessagePartExcerptSource(message)
        _ = self.messagePartExcerptCache.excerpt(for: source)
        return source
    }

    /// The quote above one of an assistant turn's messages that answers an earlier message.
    private func agentQuote(_ turn: AssistantTurn, _ index: Int, layout: TranscriptRowLayout) -> TranscriptPart.ReplyQuote? {
        guard let id = Self.messageId(turn, index), let quote = layout.decoration.messageQuotes[id] else { return nil }
        let width = min(TranscriptMetrics.contentWidth(rowWidth: layout.width), TranscriptMetrics.maxCardWidth)
        return self.replyQuote(quote, isLocating: layout.decoration.isLocating, width: width)
    }

    private enum ThinkingSteps { case hidden, live, grouped }

    /// How a message another agent, an automation or a helper sent here is shown: as theirs.
    private func sender(_ sender: MessageSender) -> (name: String, marker: String, avatar: TranscriptPart.Avatar,
                                                     source: TranscriptRowLayout.SourceChat?)
    {
        let agents = self.context.gateway.agents
        let name = sender.displayName(agents: agents)
        let marker = sender.marker(agents: agents, receivingAgentId: self.context.agent.id)
        let agent = sender.agent(in: agents)
        // Never live: the companion on the latest reply shows what this chat's agent is doing.
        var avatar = TranscriptPart.Avatar(text: String(name.prefix(1)).uppercased(), emoji: agent?.emoji,
                                           color: TranscriptColors.agentAvatar, seed: sender.agentId ?? name)
        switch sender.kind {
        case .agent: avatar.creature = agent.flatMap { self.settings.agentStyles[$0.id] }
        case .automation: avatar.symbol = "clock.arrow.circlepath"
        case .helper: avatar.symbol = "sparkles"
        }
        let source = sender.sessionKey.flatMap { key in
            sender.canOpenSource && key != self.context.sessionKey
                ? TranscriptRowLayout.SourceChat(sessionKey: key, title: L("Open \(name)’s Chat")) : nil
        }
        return (name, marker, avatar, source)
    }

    /// Avatar on the left, name line on top, content stacked below it.
    private func scaffold(avatar: TranscriptPart.Avatar, header: TranscriptPart.Header,
                          into layout: inout TranscriptRowLayout, content: (inout Stack, inout TranscriptRowLayout) -> Void)
    {
        let metrics = TranscriptMetrics.self
        let x = metrics.contentX
        let contentWidth = metrics.contentWidth(rowWidth: layout.width)
        let top = metrics.verticalPadding
        let headerHeight = TranscriptStyle.lineHeight(self.style.headline)
        layout.parts.append(.init(part: .avatar(avatar), frame: CGRect(x: metrics.sidePadding, y: top, width: metrics.avatar, height: metrics.avatar)))
        layout.parts.append(.init(part: .header(header), frame: CGRect(x: x, y: top, width: contentWidth, height: headerHeight)))
        var stack = Stack(x: x, y: top + headerHeight + metrics.headerGap, width: contentWidth)
        content(&stack, &layout)
        layout.parts += stack.parts
        let bottom = stack.isEmpty ? top + headerHeight : stack.y
        layout.height = ceil(max(bottom, top + metrics.avatar) + metrics.verticalPadding)
    }

    struct Stack {
        let x: CGFloat
        var y: CGFloat
        let width: CGFloat
        var parts: [TranscriptRowLayout.Placed] = []
        var isEmpty: Bool { self.parts.isEmpty }

        init(x: CGFloat, y: CGFloat, width: CGFloat) {
            self.x = x
            self.y = y
            self.width = width
        }

        /// The y where the next item starts, after the spacing that separates it from the last one.
        mutating func next(spacing: CGFloat = TranscriptMetrics.blockSpacing) -> CGFloat {
            if !self.parts.isEmpty { self.y += spacing }
            return self.y
        }

        mutating func add(_ part: TranscriptPart, height: CGFloat, width: CGFloat? = nil,
                          spacing: CGFloat = TranscriptMetrics.blockSpacing)
        {
            let top = self.next(spacing: spacing)
            self.parts.append(.init(part: part, frame: CGRect(x: self.x, y: top, width: min(width ?? self.width, self.width), height: height)))
            self.y = top + height
        }
    }
}
