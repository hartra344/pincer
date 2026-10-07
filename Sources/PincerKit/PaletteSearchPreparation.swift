import Foundation
import Observation
import Synchronization

/// The palette's existing complete fuzzy ranking and display partition policy.
package enum PaletteSearchPreparation {
    package enum Page: Sendable, Equatable { case root, models, messages }
    /// Ranking-only environment changes do not restart or retire a message search.
    package static func ownerAfterEnvironmentChange(_ current: UUID, page: Page) -> UUID {
        page == .messages ? current : UUID()
    }
    package static func messagesAreCurrent(owner: UUID?, currentOwner: UUID, gateway: UUID?, currentGateway: UUID?) -> Bool {
        owner == currentOwner && gateway != nil && gateway == currentGateway
    }
    package static func results(_ items: [PaletteItem], bookmarks: [PaletteItem] = [], query: String,
                                page: Page, gatewaySelected: Bool, shortcut: String? = "⇧⌘F") -> [PaletteItem] {
        if case .messages = page { return items }
        var ranked = Array(PaletteMatcher.rank(items, query: query).prefix(80))
        guard case .root = page else { return ranked }
        ranked += PaletteMatcher.rank(bookmarks, query: query).prefix(10)
        return CommandPalette.addingSearchMessages(to: ranked, query: query, gatewaySelected: gatewaySelected, shortcut: shortcut)
    }

    /// Exactly one worker for this standalone preparation; consumer cancellation still drains it.
    @MainActor package static func prepare(_ items: [PaletteItem], bookmarks: [PaletteItem] = [], query: String,
                                         page: Page, gatewaySelected: Bool, shortcut: String? = "⇧⌘F") async -> [PaletteItem] {
        guard !Task.isCancelled else { return [] }
        #if DEBUG
        let probe = PaletteSearchDiagnostics.probe
        #endif
        let worker = Task.detached(priority: .userInitiated) {
            #if DEBUG
            return PaletteSearchDiagnostics.$probe.withValue(probe) {
                self.results(items, bookmarks: bookmarks, query: query, page: page, gatewaySelected: gatewaySelected, shortcut: shortcut)
            }
            #else
            return self.results(items, bookmarks: bookmarks, query: query, page: page, gatewaySelected: gatewaySelected, shortcut: shortcut)
            #endif
        }
        let result = await worker.value
        return Task.isCancelled ? [] : result
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

/// Lock-backed source admission is invalidated synchronously by Observation's change callback.
package final class PaletteSourceRevision: Sendable {
    private let value = Mutex<UInt64>(0)
    package init() {}
    package var current: UInt64 { value.withLock { $0 } }
    package func invalidate() { value.withLock { $0 &+= 1 } }
    package func changed(_ expected: UInt64) -> Bool {
        value.withLock { revision in
            guard revision == expected else { return false }
            revision &+= 1; return true
        }
    }
    package func owns(_ expected: UInt64) -> Bool { value.withLock { $0 == expected } }
}


/// Cheap presentation inputs not owned by model Observation tracking.
package struct PaletteEnvironmentKey: Equatable, Sendable {
    package let thinking: String
    package let dictationScene: UUID?
    package let readAloudIdentity: ObjectIdentifier?
    package let readAloudEnabled: Bool?
    package let sidebarTitle: String?
    package init(thinking: String = "", dictationScene: UUID? = nil, readAloudIdentity: ObjectIdentifier? = nil,
                 readAloudEnabled: Bool? = nil, sidebarTitle: String? = nil) {
        self.thinking = thinking; self.dictationScene = dictationScene; self.readAloudIdentity = readAloudIdentity
        self.readAloudEnabled = readAloudEnabled; self.sidebarTitle = sidebarTitle
    }
}

/// Per presentation: one finished display, one active worker lease, and one latest COW input.
@MainActor @Observable package final class PaletteSearchCoordinator {
    package struct Finished {
        package let items: [PaletteItem]
        package let owner: UUID
        package let revision: UInt64
        package let environment: PaletteEnvironmentKey
    }
    package private(set) var result: Finished?
    package private(set) var refreshRevision: UInt64 = 0
    @ObservationIgnored package let source = PaletteSourceRevision()
    @ObservationIgnored private let preparer = LatestWinsPreparer<[PaletteItem]>()
    @ObservationIgnored package private(set) var isPresenting = false
    #if DEBUG
    @ObservationIgnored package var didPrepare: (@Sendable () async -> Void)?
    package var actualWorkerTask: Task<Void, Never>? { preparer.workerTask }
    package var activeCount: Int { preparer.activeCount }
    package var pendingCount: Int { preparer.pendingCount }
    #endif
    package init() {}
    package func appear() { if !isPresenting { source.invalidate(); isPresenting = true } }
    package func invalidate(clearDisplay: Bool = false) {
        source.invalidate(); preparer.invalidate()
        if clearDisplay { result = nil }
    }
    package func disappear() { isPresenting = false; invalidate(clearDisplay: true) }
    package func refreshSource(ifCurrent revision: UInt64) {
        guard isPresenting, source.owns(revision) else { return }
        refreshRevision &+= 1
    }
    package func owns(_ owner: UUID, environment: PaletteEnvironmentKey? = nil) -> Bool {
        guard isPresenting, let result else { return false }
        return result.owner == owner && source.owns(result.revision) && (environment == nil || environment == result.environment)
    }
    package func prepare(_ items: [PaletteItem], bookmarks: [PaletteItem], query: String,
                         page: PaletteSearchPreparation.Page, gatewaySelected: Bool, shortcut: String?,
                         owner: UUID, revision: UInt64, environment: PaletteEnvironmentKey = .init()) async -> Bool {
        guard !Task.isCancelled, isPresenting, source.owns(revision) else { return false }
        #if DEBUG
        let probe = PaletteSearchDiagnostics.probe
        #endif
        // `accept` runs only for the current, uncancelled request, so it is where the display is committed.
        var output: [PaletteItem]?
        return await preparer.prepare(
            accept: { [self] in
                guard isPresenting, source.owns(revision), let items = output else { return false }
                result = Finished(items: items, owner: owner, revision: revision, environment: environment)
                return true
            },
            start: { [self] in
                #if DEBUG
                let hook = didPrepare
                return {
                    let value = PaletteSearchDiagnostics.$probe.withValue(probe) {
                        PaletteSearchPreparation.results(items, bookmarks: bookmarks, query: query,
                            page: page, gatewaySelected: gatewaySelected, shortcut: shortcut)
                    }
                    await hook?()
                    return value
                }
                #else
                return {
                    PaletteSearchPreparation.results(items, bookmarks: bookmarks, query: query,
                        page: page, gatewaySelected: gatewaySelected, shortcut: shortcut)
                }
                #endif
            },
            finished: { output = $0 }) != nil
    }
}
