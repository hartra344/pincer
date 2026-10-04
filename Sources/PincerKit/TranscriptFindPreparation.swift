import Foundation

/// The actual detached matcher and row-index construction used by Find.
@MainActor
package final class TranscriptFindPreparation {
    package struct Result: Sendable {
        package let matches: [TranscriptSearch.Match]
        package let rowIndex: [String: Int]
    }
    package init() {}
    #if DEBUG
    package var probe: TranscriptFindWorkerProbe?
    #endif
    package func prepare(query: String, entries: [TranscriptEntry], options: TranscriptSearch.Options) async -> Result {
        #if DEBUG
        let probe = self.probe
        #endif
        return await Task.detached(priority: .userInitiated) {
            #if DEBUG
            let ordinal = probe?.enter()
            defer { probe?.exit() }
            if let ordinal { await probe?.hold(ordinal) }
            #endif
            return Result(matches: TranscriptSearch.matches(query, in: entries, options: options),
                          rowIndex: Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }))
        }.value
    }
}

#if DEBUG
/// Per-instance, fixed scalar diagnostics at actual worker entry and completion. No transcript data.
package final class TranscriptFindWorkerProbe: @unchecked Sendable {
    package struct Snapshot: Sendable {
        package let entered: Int
        package let completed: Int
        package let active: Int
        package let maximumActive: Int
        package let mainEntries: Int
    }
    private let lock = NSLock()
    private var entered = 0
    private var completed = 0
    private var active = 0
    private var maximumActive = 0
    private var mainEntries = 0
    private let gate: (@Sendable (Int) async -> Void)?
    package init(gate: (@Sendable (Int) async -> Void)? = nil) { self.gate = gate }
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
        return Snapshot(entered: self.entered, completed: self.completed, active: self.active,
                        maximumActive: self.maximumActive, mainEntries: self.mainEntries)
    }
}
#endif
