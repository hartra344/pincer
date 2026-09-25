import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One row of the native transcript list (`TranscriptList`): a message, or the spinner shown while
/// older history is still streaming in above.
enum TranscriptRow: Equatable {
    case loadingOlder
    case entry(TranscriptEntry)

    var id: String {
        switch self {
        case .loadingOlder: "loading-older"
        case let .entry(entry): entry.id
        }
    }

    /// A message the owner just sent that the Gateway hasn't committed yet. The list jumps to it,
    /// even if the reader had scrolled up, and then follows the reply.
    var isPendingSend: Bool {
        if case let .entry(.user(item)) = self { item.isPending } else { false }
    }

    @MainActor static func rows(for chat: ChatStore) -> [TranscriptRow] {
        (chat.hasMoreHistory ? [.loadingOlder] : []) + chat.entries.map(TranscriptRow.entry)
    }
}

/// Which thinking blocks and tool cards are open. Kept outside the rows because the list recycles
/// row views: state stored in a row view would follow it to another message.
@MainActor
final class TranscriptDisclosure {
    private var expanded: [String: Bool] = [:]

    func isExpanded(_ id: String, default value: Bool) -> Bool {
        self.expanded[id] ?? value
    }

    func set(_ id: String, expanded: Bool) {
        self.expanded[id] = expanded
    }

    /// Records a default once, so it sticks when the condition that chose it (a live stream) ends.
    func setIfUnset(_ id: String, expanded: Bool) {
        if self.expanded[id] == nil { self.expanded[id] = expanded }
    }
}

/// Everything a transcript row needs besides its own content.
@MainActor
struct TranscriptContext {
    let gateway: GatewayStore
    let disclosure: TranscriptDisclosure
    let agent: AgentSummary
    let sessionKey: String
    /// Opens an image full size. Provided by `ChatView`, which owns the sheet.
    let previewImage: (ImageRef) -> Void

    func differs(from other: TranscriptContext) -> Bool {
        self.agent != other.agent || self.sessionKey != other.sessionKey || self.disclosure !== other.disclosure
    }
}

/// What row views can ask of the list they're in.
@MainActor
protocol TranscriptRowActions: AnyObject {
    func setExpanded(_ key: String, _ expanded: Bool, row: String)
    func openRun(_ sessionKey: String)
    func preview(_ ref: ImageRef)
    func open(_ url: URL)
    func loadImage(_ ref: ImageRef)
}

/// Lays out rows for the AppKit and UIKit lists and tells them when a row's layout is stale:
/// its disclosure toggled, an image it shows loaded, a subagent run it links to appeared, or a
/// setting or the text size changed.
@MainActor
final class TranscriptRenderer: TranscriptRowActions {
    private struct Entry {
        let row: TranscriptRow
        let layout: TranscriptRowLayout
    }

    private enum ImageState: Equatable { case loading, loaded, failed }

    private(set) var context: TranscriptContext
    private var settings: TranscriptSettings
    private var cache: [String: Entry] = [:]
    private var imageRows: [String: Set<String>] = [:]
    private var imageStates: [String: ImageState] = [:]
    private var spawnRows: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    /// Rows whose layout changed (nil means all of them), and a row to hold still on screen while
    /// they change, when the change came from a click in that row.
    private var serial = 0
    var onInvalidate: ((_ ids: Set<String>?, _ keepInPlace: String?) -> Void)?

    init(context: TranscriptContext) {
        self.context = context
        self.settings = .current(for: context)
        self.observeImages()
        self.observeSessions()
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        #if os(iOS)
        self.observers.append(center.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                TranscriptStyle.reload()
                self?.invalidateAll()
            }
        })
        #endif
    }

    isolated deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    func update(context: TranscriptContext) {
        let changed = context.differs(from: self.context)
        self.context = context
        if changed {
            self.settings = .current(for: context)
            self.reset()
        } else {
            self.settingsChanged()
        }
    }

    /// The row laid out at `width`, from cache when neither has changed.
    func layout(for row: TranscriptRow, width: CGFloat) -> TranscriptRowLayout {
        if let entry = self.cache[row.id], entry.layout.width == width, entry.row == row { return entry.layout }
        var layout = TranscriptLayoutBuilder(context: self.context, settings: self.settings).layout(row, width: width)
        self.serial += 1
        layout.serial = self.serial
        self.cache[row.id] = Entry(row: row, layout: layout)
        let loader = self.context.gateway.images
        for ref in layout.images {
            let key = ref.cacheKey
            self.imageRows[key, default: []].insert(row.id)
            self.imageStates[key] = loader.cached(ref) != nil ? .loaded : loader.hasFailed(ref) ? .failed : .loading
        }
        if layout.hasSpawns { self.spawnRows.insert(row.id) } else { self.spawnRows.remove(row.id) }
        return layout
    }

    func reset() {
        self.cache.removeAll()
        self.imageRows.removeAll()
        self.imageStates.removeAll()
        self.spawnRows.removeAll()
    }

    private func invalidate(_ ids: Set<String>, keepInPlace: String? = nil) {
        guard !ids.isEmpty else { return }
        for id in ids { self.cache[id] = nil }
        self.onInvalidate?(ids, keepInPlace)
    }

    private func invalidateAll() {
        self.reset()
        self.onInvalidate?(nil, nil)
    }

    // MARK: Observation

    private func observeImages() {
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
            guard let rows = self.imageRows[key], let id = rows.first,
                  let ref = self.cache[id]?.layout.images.first(where: { $0.cacheKey == key }) else { continue }
            let now: ImageState = loader.cached(ref) != nil ? .loaded : loader.hasFailed(ref) ? .failed : .loading
            if now != old {
                self.imageStates[key] = now
                stale.formUnion(rows)
            }
        }
        self.invalidate(stale)
    }

    private func observeSessions() {
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
            let builder = TranscriptLayoutBuilder(context: self.context, settings: self.settings)
            for tool in turn.tools where builder.spawnedRun(tool) != entry.layout.runs[tool.id] {
                stale.insert(id)
                break
            }
        }
        self.invalidate(stale)
    }

    @discardableResult private func settingsChanged() -> Bool {
        let settings = TranscriptSettings.current(for: self.context)
        guard settings != self.settings else { return false }
        self.settings = settings
        self.invalidateAll()
        return true
    }

    // MARK: TranscriptRowActions

    func setExpanded(_ key: String, _ expanded: Bool, row: String) {
        self.context.disclosure.set(key, expanded: expanded)
        self.invalidate([row], keepInPlace: row)
    }

    func openRun(_ sessionKey: String) {
        self.context.gateway.selectedKey = sessionKey
    }

    func preview(_ ref: ImageRef) {
        self.context.previewImage(ref)
    }

    func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func loadImage(_ ref: ImageRef) {
        self.context.gateway.images.load(ref, sessionKey: self.context.sessionKey)
    }
}

/// Scroll behavior shared by the AppKit and UIKit transcripts.
enum TranscriptLayout {
    /// Within this distance of the end, new content keeps the transcript scrolled to the bottom.
    static let stickToBottomDistance: CGFloat = 80
    static let rowSpacing: CGFloat = 2
    static let verticalInset: CGFloat = 12

    /// Rough height for a row that hasn't been laid out yet, so the scroll bar and off-screen
    /// positions are close before the row is laid out for real.
    static func estimatedHeight(_ row: TranscriptRow, width: CGFloat) -> CGFloat {
        let textWidth = max(width - TranscriptMetrics.contentX - TranscriptMetrics.sidePadding, 120)
        let charactersPerLine = max(textWidth / 7, 10)
        func lines(_ text: String) -> CGFloat {
            var total: CGFloat = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                total += max(1, (CGFloat(line.count) / charactersPerLine).rounded(.up))
            }
            return total
        }
        let scaffold: CGFloat = 12 + 22
        switch row {
        case .loadingOlder:
            return 36
        case .entry(.marker):
            return 32
        case let .entry(.user(item)):
            let images = item.blocks.filter { if case .image = $0 { true } else { false } }.count
            let files = item.blocks.filter { if case .file = $0 { true } else { false } }.count
            return scaffold + lines(item.plainText) * 18 + (images > 0 ? 240 : 0) + CGFloat(files) * 36
        case let .entry(.assistant(turn)):
            var height = scaffold
            if turn.isStreaming, ThinkingDisplay.current != .none {
                if !turn.thinking.isEmpty { height += 26 }
                height += CGFloat(turn.tools.count) * 34
            } else if ThinkingDisplay.current == .all, !turn.thinking.isEmpty || !turn.tools.isEmpty {
                height += 26
            }
            if !turn.text.isEmpty { height += lines(turn.body) * 18 }
            if !turn.images.isEmpty { height += 240 }
            height += CGFloat(turn.files.count) * 36
            return height
        }
    }
}
