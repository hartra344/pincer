import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension TranscriptRenderer {
    // MARK: TranscriptRowActions

    func setExpanded(_ key: String, _ expanded: Bool, row: String) {
        self.context.disclosure.set(key, expanded: expanded)
        self.invalidate([row], keepInPlace: row)
    }

    /// Search within a tool card: opens or closes it, sets the query or the current match. Only the
    /// card's row is laid out again; `reveal` scrolls to the current match.
    func setToolSearch(_ toolId: String, row: String, open: Bool? = nil, query: String? = nil, current: Int? = nil,
                       reveal: Bool = false)
    {
        let store = self.context.disclosure.toolSearch
        var state = store.state(for: toolId)
        if let query { state.query = query }
        if let current { state.current = current }
        store.set(state, for: toolId)
        if let open { self.context.disclosure.set(ToolCardSearchStore.key(toolId), expanded: open) }
        self.invalidate([row], keepInPlace: row)
        if reveal { self.onReveal?(row) }
    }

    func openRun(_ sessionKey: String) {
        self.context.gateway.selectedKey = sessionKey
    }

    func openChat(_ sessionKey: String) {
        let gateway = self.context.gateway
        gateway.selectedKey = gateway.resolveSessionKey(sessionKey)
    }

    func openMCPServer(_ name: String) {
        self.context.openMCPServer(name)
    }

    func preview(_ ref: ImageRef) {
        self.context.previewImage(ref)
    }

    func previewHTML(_ html: String) {
        self.context.previewHTML(html)
    }

    func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func openBrowserPage(_ page: BrowserPagePreview) {
        if !self.context.openBrowserPage(page) { self.open(page.url) }
    }

    func loadPagePreview(_ url: URL) {
        let previews = self.context.gateway.pagePreviews
        if previews.preview(for: url) == nil, !self.requestedPages.contains(url) {
            self.requestedPages.append(url)
            if self.requestedPages.count > 32 { self.requestedPages.removeFirst() }
        }
        previews.load(url)
    }

    /// Updates which turn owns each tab's screenshot, and returns the rows whose card eligibility
    /// changed (their cached layouts are marked stale; the caller re-measures them).
    func updatePageTurns(rows: [TranscriptRow], tailOnly: Bool) -> Set<String> {
        var turns = tailOnly ? self.pageTurns : [:]
        let source = tailOnly ? Array(rows.suffix(1)) : rows
        for row in source {
            guard case let .entry(.assistant(turn)) = row else { continue }
            for page in BrowserPagePreview.latestPerTab(turn.tools) { turns[page.tabKey] = turn.id }
        }
        guard turns != self.pageTurns else { return [] }
        self.pageTurns = turns
        var stale: Set<String> = []
        for id in self.pageRows {
            guard let entry = self.cache[id] else { continue }
            if entry.layout.pages.contains(where: { $0.screenshotEligible != (turns[$0.tabKey] == $0.turnId) }) {
                stale.insert(id)
            }
        }
        self.markLayoutInvalidated(stale)
        return stale
    }
}

extension TranscriptRenderer {
    func loadImage(_ ref: ImageRef) {
        self.context.gateway.images.load(ref, sessionKey: self.context.sessionKey)
    }

    func loadFilePreview(_ file: FileRef) {
        self.context.gateway.files.loadPreview(file, sessionKey: self.context.sessionKey)
    }

    func saveFile(_ file: FileRef) async -> Bool {
        let context = self.context
        guard let data = await context.gateway.files.data(for: file, sessionKey: context.sessionKey) else { return false }
        context.saveFile(file, data)
        return true
    }

    func previewHTML(_ file: FileRef) async -> Bool {
        let context = self.context
        guard let data = await context.gateway.files.data(for: file, sessionKey: context.sessionKey) else { return false }
        let html = await Task.detached(priority: .userInitiated) { HTMLAttachmentSource.decode(data) }.value
        guard let html else { return false }
        context.previewHTML(html)
        return true
    }

    func quickLook(_ file: FileRef) async -> Bool {
        let context = self.context
        guard let data = await context.gateway.files.data(for: file, sessionKey: context.sessionKey) else { return false }
        let name = file.name, mimeType = file.mimeType
        let url = await Task.detached(priority: .userInitiated) {
            try? FilePreviewFiles.write(data, name: name, mimeType: mimeType)
        }.value
        guard let url else { return false }
        context.quickLook(url)
        return true
    }

    func copyLink(to messageId: String) {
        self.context.copyLink(messageId)
    }

    func toggleBookmark(_ messageId: String) {
        self.context.toggleBookmark(messageId)
    }

    func isBookmarked(_ messageId: String) -> Bool {
        self.context.isBookmarked(messageId)
    }

    func reply(to messageId: String) {
        self.context.reply(messageId)
    }
}
