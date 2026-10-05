import Foundation

/// The actual detached matcher and row-index construction used by Find.
@MainActor
package final class TranscriptFindPreparation {
    package struct Result: Sendable {
        package enum Status: Sendable { case completed, superseded, canceled }
        package let status: Status
        /// Usable only for a completed request; terminal non-completions are explicit statuses.
        package let matches: [TranscriptSearch.Match]
        package let rowIndex: [String: Int]
        fileprivate static func terminal(_ status: Status) -> Result {
            Result(status: status, matches: [], rowIndex: [:])
        }
    }
    private struct Request {
        let token: UUID
        let query: String
        let entries: [TranscriptEntry]
        let options: TranscriptSearch.Options
        let continuation: CheckedContinuation<Result, Never>
        #if DEBUG
        let probe: TranscriptFindWorkerProbe?
        #endif
    }
    private var worker: Task<Void, Never>?
    private var active: Request?
    private var pending: Request?
    package init() {}
    #if DEBUG
    package var probe: TranscriptFindWorkerProbe?
    package var activeTaskForChecks: Task<Void, Never>? { self.worker }
    #endif
    package func prepare(query: String, entries: [TranscriptEntry], options: TranscriptSearch.Options) async -> Result {
        #if DEBUG
        self.probe?.request()
        #endif
        guard !Task.isCancelled else { return .terminal(.canceled) }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .terminal(.canceled))
                    return
                }
                #if DEBUG
                let request = Request(token: token, query: query, entries: entries, options: options,
                                      continuation: continuation, probe: self.probe)
                #else
                let request = Request(token: token, query: query, entries: entries, options: options,
                                      continuation: continuation)
                #endif
                if self.worker != nil {
                    let replaced = self.pending
                    self.pending = request
                    replaced?.continuation.resume(returning: .terminal(.superseded))
                } else {
                    self.active = request
                    self.worker = Task { await self.run() }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPending(token) }
        }
    }
    private func cancelPending(_ token: UUID) {
        guard self.pending?.token == token else { return }
        let canceled = self.pending
        self.pending = nil
        canceled?.continuation.resume(returning: .terminal(.canceled))
    }
    private func run() async {
        while let current = self.active {
            self.active = nil
            #if DEBUG
            let probe = current.probe
            probe?.reserveLease()
            #endif
            let query = current.query
            let entries = current.entries
            let options = current.options
            let result = await Task.detached(priority: .userInitiated) {
                #if DEBUG
                let ordinal = probe?.enter()
                defer { probe?.exit() }
                if let ordinal { await probe?.hold(ordinal) }
                #endif
                return Result(status: .completed, matches: TranscriptSearch.matches(query, in: entries, options: options),
                              rowIndex: Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }))
            }.value
            #if DEBUG
            probe?.releaseLease()
            #endif
            current.continuation.resume(returning: result)
            // Capacity is reused only after the actual detached worker has returned.
            guard let next = self.pending else {
                self.worker = nil
                return
            }
            self.pending = nil
            self.active = next
        }
    }
}

#if DEBUG
/// Per-instance, fixed scalar diagnostics at actual worker entry and completion. No transcript data.
package final class TranscriptFindWorkerProbe: @unchecked Sendable {
    package struct Snapshot: Sendable {
        package let requested: Int
        package let leases: Int
        package let maximumLeases: Int
        package let entered: Int
        package let completed: Int
        package let active: Int
        package let maximumActive: Int
        package let mainEntries: Int
    }
    private let lock = NSLock()
    private var requested = 0
    private var leases = 0
    private var maximumLeases = 0
    private var entered = 0
    private var completed = 0
    private var active = 0
    private var maximumActive = 0
    private var mainEntries = 0
    private let gate: (@Sendable (Int) async -> Void)?
    package init(gate: (@Sendable (Int) async -> Void)? = nil) { self.gate = gate }
    // Request and lease decisions are synchronous on Main before worker launch/first await.
    // A lease is released only after the actual detached task value has returned.
    fileprivate func request() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.requested = min(32, self.requested + 1)
    }
    fileprivate func reserveLease() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.leases = min(32, self.leases + 1)
        self.maximumLeases = max(self.maximumLeases, self.leases)
    }
    fileprivate func releaseLease() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.leases = max(0, self.leases - 1)
    }
    fileprivate func enter() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entered = min(32, self.entered + 1)
        self.active = min(32, self.active + 1)
        self.maximumActive = max(self.maximumActive, self.active)
        if Thread.isMainThread { self.mainEntries = min(32, self.mainEntries + 1) }
        return self.entered
    }
    fileprivate func exit() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.completed = min(32, self.completed + 1)
        self.active = max(0, self.active - 1)
    }
    fileprivate func hold(_ ordinal: Int) async { await self.gate?(ordinal) }
    package var snapshot: Snapshot {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Snapshot(requested: self.requested, leases: self.leases, maximumLeases: self.maximumLeases, entered: self.entered, completed: self.completed, active: self.active,
                        maximumActive: self.maximumActive, mainEntries: self.mainEntries)
    }
}
#endif
