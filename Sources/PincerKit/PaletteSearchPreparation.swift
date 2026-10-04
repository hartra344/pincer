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
    private final class Cancellation: Sendable {
        private let flag = Mutex(false)
        var isCanceled: Bool { flag.withLock { $0 } }
        func cancel() { flag.withLock { $0 = true } }
    }
    private struct Job: Sendable {
        let ticket: UUID, owner: UUID
        let revision: UInt64
        let environment: PaletteEnvironmentKey
        let items: [PaletteItem], bookmarks: [PaletteItem]
        let query: String, page: PaletteSearchPreparation.Page
        let gatewaySelected: Bool, shortcut: String?
        let cancellation: Cancellation
        let completion: @MainActor @Sendable (Bool) -> Void
        #if DEBUG
        let probe: PaletteSearchProbe?
        #endif
    }
    package struct Finished {
        package let items: [PaletteItem]
        package let owner: UUID
        package let revision: UInt64
        package let environment: PaletteEnvironmentKey
    }
    package private(set) var result: Finished?
    package private(set) var refreshRevision: UInt64 = 0
    @ObservationIgnored package let source = PaletteSourceRevision()
    @ObservationIgnored private var current: UUID?
    @ObservationIgnored private var active: UUID?
    @ObservationIgnored private var pending: Job?
    @ObservationIgnored package private(set) var isPresenting = false
    #if DEBUG
    @ObservationIgnored package var didPrepare: (@Sendable () async -> Void)?
    @ObservationIgnored package private(set) var actualWorkerTask: Task<Void, Never>?
    package var activeCount: Int { active == nil ? 0 : 1 }
    package var pendingCount: Int { pending == nil ? 0 : 1 }
    #endif
    package init() {}
    package func appear() { if !isPresenting { source.invalidate(); isPresenting = true } }
    package func invalidate(clearDisplay: Bool = false) {
        source.invalidate(); current = nil
        if clearDisplay { result = nil }
        let old = pending; pending = nil; old?.completion(false)
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
    private func cancel(_ ticket: UUID) {
        if pending?.ticket == ticket { let old = pending; pending = nil; old?.completion(false) }
        if current == ticket { current = nil }
    }
    package func prepare(_ items: [PaletteItem], bookmarks: [PaletteItem], query: String,
                         page: PaletteSearchPreparation.Page, gatewaySelected: Bool, shortcut: String?,
                         owner: UUID, revision: UInt64, environment: PaletteEnvironmentKey = .init()) async -> Bool {
        guard !Task.isCancelled, isPresenting, source.owns(revision) else { return false }
        let ticket = UUID(), cancellation = Cancellation()
        #if DEBUG
        let probe = PaletteSearchDiagnostics.probe
        #endif
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, source.owns(revision), isPresenting else { continuation.resume(returning: false); return }
                current = ticket
                #if DEBUG
                let job = Job(ticket: ticket, owner: owner, revision: revision, environment: environment, items: items, bookmarks: bookmarks,
                    query: query, page: page, gatewaySelected: gatewaySelected, shortcut: shortcut,
                    cancellation: cancellation, completion: { continuation.resume(returning: $0) }, probe: probe)
                #else
                let job = Job(ticket: ticket, owner: owner, revision: revision, environment: environment, items: items, bookmarks: bookmarks,
                    query: query, page: page, gatewaySelected: gatewaySelected, shortcut: shortcut,
                    cancellation: cancellation, completion: { continuation.resume(returning: $0) })
                #endif
                if active != nil { let old = pending; pending = job; old?.completion(false) }
                else { start(job) }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(ticket) }
        }
    }
    private func start(_ job: Job) {
        active = job.ticket
        #if DEBUG
        let hook = didPrepare
        #endif
        let task = Task {
            let output = await Task.detached(priority: .userInitiated) {
                #if DEBUG
                let value = PaletteSearchDiagnostics.$probe.withValue(job.probe) {
                    PaletteSearchPreparation.results(job.items, bookmarks: job.bookmarks, query: job.query,
                        page: job.page, gatewaySelected: job.gatewaySelected, shortcut: job.shortcut)
                }
                await hook?()
                return value
                #else
                return PaletteSearchPreparation.results(job.items, bookmarks: job.bookmarks, query: job.query,
                    page: job.page, gatewaySelected: job.gatewaySelected, shortcut: job.shortcut)
                #endif
            }.value
            let accepted = isPresenting && current == job.ticket && source.owns(job.revision) && !job.cancellation.isCanceled
            active = nil
            #if DEBUG
            actualWorkerTask = nil
            #endif
            if accepted { result = Finished(items: output, owner: job.owner, revision: job.revision, environment: job.environment) }
            let next = pending; pending = nil
            if let next { start(next) }
            job.completion(accepted)
        }
        #if DEBUG
        actualWorkerTask = task
        #endif
    }
}
