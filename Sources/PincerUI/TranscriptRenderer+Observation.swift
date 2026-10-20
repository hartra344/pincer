import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension TranscriptRenderer {
    // MARK: Observation

    func observeImages() {
        let loader = self.context.gateway.images
        withObservationTracking {
            _ = loader.images
            _ = loader.failures
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.imagesChanged()
                self?.observeImages()
            }
        }
    }

    private func imagesChanged() {
        let loader = self.context.gateway.images
        var stale: Set<String> = []
        for (key, old) in self.imageStates {
            guard let rows = self.imageRows[key], let ref = self.imageRefs[key] else { continue }
            let now: ImageState = loader.images[ref.cacheKey] != nil ? .loaded : loader.hasFailed(ref) ? .failed : .loading
            if now != old {
                self.imageStates[key] = now
                stale.formUnion(rows)
            }
        }
        self.invalidate(stale)
    }

    func observePagePreviews() {
        let previews = self.context.gateway.pagePreviews
        withObservationTracking {
            // Reading either store property tracks the whole property.
            _ = previews.preview(for: Self.pagePreviewProbeURL)
            _ = previews.screenshot(forTab: "")
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.pagePreviewsChanged()
                self?.observePagePreviews()
            }
        }
    }

    private static let pagePreviewProbeURL = URL(string: "https://pincer.invalid/")!

    private func pagePreviewsChanged() {
        let previews = self.context.gateway.pagePreviews
        var stale: Set<String> = []
        for id in self.pageRows {
            guard let entry = self.cache[id] else { continue }
            for page in entry.layout.pages {
                let link = previews.preview(for: page.url)
                let screenshotKey = page.screenshotEligible ? previews.screenshot(forTab: page.tabKey)?.cacheKey : nil
                if link?.image?.cacheKey != page.imageKey || link?.favicon?.cacheKey != page.faviconKey
                    || screenshotKey != page.screenshotKey
                {
                    stale.insert(id)
                    break
                }
            }
        }
        self.invalidate(stale)
    }

    func observeFiles() {
        let files = self.context.gateway.files
        withObservationTracking {
            _ = files.previews
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.filesChanged()
                self?.observeFiles()
            }
        }
    }

    private func filesChanged() {
        let files = self.context.gateway.files
        var stale: Set<String> = []
        for (key, old) in self.filePreviews {
            let now = files.previews[key]
            if now != old {
                self.filePreviews[key] = .some(now)
                stale.formUnion(self.fileRows[key] ?? [])
            }
        }
        self.invalidate(stale)
    }

    func observeSessions() {
        let gateway = self.context.gateway
        withObservationTracking {
            _ = gateway.sessions
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sessionsChanged()
                self?.observeSessions()
            }
        }
    }

    private func sessionsChanged() {
        // The session's reasoningLevel feeds the settings.
        if self.settingsChanged() { return }
        guard !self.spawnRows.isEmpty else { return }
        var stale: Set<String> = []
        for id in self.spawnRows {
            guard let entry = self.cache[id], case let .entry(.assistant(turn)) = entry.row else { continue }
            let builder = TranscriptLayoutBuilder(context: self.context, settings: self.settings,
                                                  messagePartExcerptCache: self.messagePartExcerptCache)
            for tool in turn.tools where builder.spawnedRun(tool) != entry.layout.runs[tool.id] {
                stale.insert(id)
                break
            }
        }
        self.invalidate(stale)
    }

    /// Reactions (yours, shared and the agent's), quotes whose original loaded, and a quote's lookup.
    /// Quote completion also invalidates cold/in-flight premeasure work through the controller's
    /// existing full-invalidation callback, rather than only comparing completed cached rows.
    func observeQuoteReadiness() {
        guard let chat = self.context.chat else { return }
        withObservationTracking {
            _ = chat.quotePreviewRevision
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, chat === self.context.chat else { return }
                self.invalidateAll()
                self.observeQuoteReadiness()
            }
        }
    }

    func observeDecorations() {
        guard let chat = self.context.chat else { return }
        let gateway = self.context.gateway
        withObservationTracking {
            _ = chat.items
            _ = chat.agentReactions
            _ = chat.sharedReactions
            _ = chat.reactionSelfId
            _ = gateway.sessionReactionsOff
            _ = chat.locatingReplyId
            _ = chat.branchAnchorId
            _ = chat.canSwitchBranches
            _ = chat.isRunning
            _ = gateway.reactions
            _ = BookmarkStore.shared(gatewayId: gateway.id).bookmarks
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, chat === self.context.chat else { return }
                self.decorationsChanged()
                self.observeDecorations()
            }
        }
    }

    private func decorationsChanged() {
        let builder = TranscriptLayoutBuilder(context: self.context, settings: self.settings, flash: self.flash,
                                              messagePartExcerptCache: self.messagePartExcerptCache)
        var stale: Set<String> = []
        for (id, entry) in self.cache where builder.decoration(for: entry.row) != entry.layout.decoration {
            stale.insert(id)
        }
        self.invalidate(stale)
    }

    /// The 👀 on your latest message comes and goes with runs, so only its old and new rows update.
    func observeAck() {
        guard let chat = self.context.chat else { return }
        let ack = withObservationTracking {
            chat.ackMessageId
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, chat === self.context.chat else { return }
                self.observeAck()
            }
        }
        guard ack != self.ack else { return }
        let old = self.ack
        self.ack = ack
        self.invalidate(Set([old, ack].compactMap { $0 }.compactMap(self.rowId(containing:))))
    }

    /// The transcript row showing a message.
    func rowId(containing messageId: String) -> String? {
        for entry in self.context.chat?.entries ?? [] {
            switch entry {
            case let .user(item) where item.transcriptId == messageId: return entry.id
            case let .assistant(turn) where turn.textIds.contains(messageId): return entry.id
            default: continue
            }
        }
        return nil
    }

    func setFlash(_ messageId: String?) {
        let old = self.flash
        self.flash = messageId
        self.invalidate(Set([old, messageId].compactMap { $0 }.compactMap(self.rowId(containing:))))
    }

    #if os(iOS)
    /// The list's light/dark style changed: rich blocks (diagrams, math) are drawn per appearance,
    /// so rebuild rows if the rendered palette differs. iOS renders app-switcher snapshots in both
    /// styles while backgrounded; those flips are skipped and re-checked on becoming active.
    func appearanceChanged() {
        guard UIApplication.shared.applicationState != .background else { return }
        self.settingsChanged()
    }
    #endif

    @discardableResult func settingsChanged() -> Bool {
        let settings = TranscriptSettings.current(for: self.context)
        guard settings != self.settings else { return false }
        self.settings = settings
        self.invalidateAll()
        return true
    }
}

extension TranscriptRenderer {
    func observeConnection() {
        let gateway = self.context.gateway
        let connected = withObservationTracking {
            gateway.state.isConnected
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeConnection() }
        }
        guard connected, !self.requestedPages.isEmpty else { return }
        for url in self.requestedPages where gateway.pagePreviews.preview(for: url) == nil {
            gateway.pagePreviews.load(url)
        }
    }
}
