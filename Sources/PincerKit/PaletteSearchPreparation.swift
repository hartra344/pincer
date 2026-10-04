import Foundation

/// The palette's existing complete fuzzy ranking and display partition policy.
package enum PaletteSearchPreparation {
    package enum Page: Sendable { case root, models, messages }
    package static func results(_ items: [PaletteItem], bookmarks: [PaletteItem] = [], query: String,
                                page: Page, gatewaySelected: Bool, shortcut: String? = "⇧⌘F") -> [PaletteItem] {
        if case .messages = page { return items }
        var ranked = Array(PaletteMatcher.rank(items, query: query).prefix(80))
        guard case .root = page else { return ranked }
        ranked += PaletteMatcher.rank(bookmarks, query: query).prefix(10)
        return CommandPalette.addingSearchMessages(to: ranked, query: query, gatewaySelected: gatewaySelected, shortcut: shortcut)
    }

    /// API-neutral: deliberately executes the same shipped synchronous kernel on Main.
    @MainActor package static func prepare(_ items: [PaletteItem], bookmarks: [PaletteItem] = [], query: String,
                                         page: Page, gatewaySelected: Bool, shortcut: String? = "⇧⌘F") async -> [PaletteItem] {
        self.results(items, bookmarks: bookmarks, query: query, page: page, gatewaySelected: gatewaySelected, shortcut: shortcut)
    }
}

#if DEBUG
package final class PaletteSearchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = [0, 0, 0], worker = [0, 0, 0]
    package init() {}
    package func record(_ boundary: Int) {
        lock.lock(); defer { lock.unlock() }
        if Thread.isMainThread { main[boundary] = min(16, main[boundary] + 1) }
        else { worker[boundary] = min(16, worker[boundary] + 1) }
    }
    package var counts: (main: [Int], worker: [Int]) {
        lock.lock(); defer { lock.unlock() }; return (main, worker)
    }
}
package enum PaletteSearchDiagnostics {
    @TaskLocal package static var probe: PaletteSearchProbe?
}
#endif
