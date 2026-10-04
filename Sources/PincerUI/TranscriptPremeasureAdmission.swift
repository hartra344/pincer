import Foundation
import PincerKit
import Synchronization

/// The descriptor contains no row or message payload. The controller remains the source owner.
final class PremeasureRequest: @unchecked Sendable {
    @MainActor weak var driver: TranscriptPremeasureDriver?
    let rowID: String
    let revision: UInt64
    @MainActor init(driver: TranscriptPremeasureDriver, rowID: String, revision: UInt64) {
        self.driver = driver
        self.rowID = rowID
        self.revision = revision
    }
}

/// Source construction is shared with the renderer's diagnostic API, but production admission
/// calls it only on the serialized worker after acquiring one current-row COW snapshot.
enum PremeasureSource {
    nonisolated static func bodies(for row: TranscriptRow, styleGeneration: Int, dark: Bool) -> [PremeasureKey]? {
        let sources: [(String, TranscriptText.Tone)]
        switch row {
        case let .entry(.user(item)):
            sources = [(item.plainText, .primary)]
            #if DEBUG
            PremeasureAdmissionProbe.record(row.id, operation: .joinedSource, source: sources.first?.0)
            #endif
        case let .entry(.assistant(turn)):
            guard !turn.isStreaming else { return nil }
            sources = turn.text.map { ($0, turn.isError ? .error : .primary) }
        default: return nil
        }
        var keys: [PremeasureKey] = []
        for (source, tone) in sources where !source.isEmpty {
            let key = PremeasureKey(source: source, tone: tone, styleGeneration: styleGeneration, dark: dark)
            if !keys.contains(key) { keys.append(key) }
        }
        return keys.isEmpty ? nil : keys
    }
}

/// One process-wide active source lease; the FIFO holds only weak-owner descriptors. A snapshot
/// can retain/fork the original COW payload and the exact join can allocate its full size. That
/// transient cost is proportional to this one input, not a fixed byte promise or free memory.
@MainActor
final class TranscriptPremeasureAdmission {
    static let shared = TranscriptPremeasureAdmission()
    static let pendingLimit = 64
    static let capacityReleased = Notification.Name("pincer.transcript.premeasure.capacity-released")
    private struct Pending: Sendable {
        let job: PremeasureJob
        let env: TextBuildEnvironment
        let epoch: TranscriptPremeasureEpoch
        let completion: @MainActor @Sendable ([PremeasuredRow]) -> Void
    }
    private let pending = BoundedMetadataFIFO<Pending>(limit: pendingLimit)
    private var lease: UUID?
    var active: Bool { self.lease != nil }
    var pendingCount: Int { self.pending.count }
    let observationCounter = PremeasureObservationCounter()
    var observationCount: Int { self.observationCounter.value.withLock { $0 } }
    #if DEBUG
    var beforeSourcePreparation: (@Sendable (String) -> Void)?
    #endif

    func submit(_ job: PremeasureJob, env: TextBuildEnvironment, epoch: TranscriptPremeasureEpoch,
                completion: @escaping @MainActor @Sendable ([PremeasuredRow]) -> Void) -> Bool {
        guard job.request != nil, job.bodies.isEmpty, job.sourceRow == nil else { return false }
        let work = Pending(job: job, env: env, epoch: epoch, completion: completion)
        if !self.active { self.start(work); return true }
        // IDs are copied COW descriptors, not text snapshots. Do not materialize a foreign ID
        // or scan an oversized one merely to wait. Such a row retries when the lease is idle.
        guard job.rowId.isContiguousUTF8,
              job.rowId.utf8.withContiguousStorageIfAvailable({ $0.count <= 512 }) == true else { return false }
        return self.pending.append(work)
    }
    func retry(_ driver: TranscriptPremeasureDriver, completion: @escaping @MainActor () -> Void) {
        driver.observeAdmissionCapacity(completion: completion)
    }
    func remove(_ driver: TranscriptPremeasureDriver) {
        self.pending.removeAll { $0.job.request?.driver === driver }
        driver.stopObservingAdmissionCapacity()
    }
    private func prepared(_ job: PremeasureJob, env: TextBuildEnvironment) -> PremeasureJob? {
        var captured: PremeasureJob?
        if let request = job.request { captured = request.driver?.capture(job, env: env) }
        else { captured = job }
        #if DEBUG
        captured?.beforeSourcePreparation = self.beforeSourcePreparation
        #endif
        return captured
    }
    private func start(_ work: Pending) {
        guard let job = self.prepared(work.job, env: work.env) else {
            work.completion([PremeasuredRow(rowId: work.job.rowId, epoch: work.job.epoch,
                                           contentWidth: work.job.contentWidth, rowRevision: work.job.rowRevision, discarded: true)])
            self.advance()
            return
        }
        let lease = UUID()
        self.lease = lease
        TranscriptPremeasurer.shared.submit([job], env: work.env, epoch: work.epoch) { [weak self] rows in
            guard let self else { return }
            // Publish/adopt before another source is captured. No completed result backlog.
            work.completion(rows)
            self.release(lease)
        }
    }
    private func advance() {
        guard !self.active else { return }
        if let work = self.pending.popFirst() { self.start(work) }
        NotificationCenter.default.post(name: Self.capacityReleased, object: self)
    }
    /// Main acquires the permit and captures ONE source before waiting. The worker never needs a
    /// main-actor hop while Main waits, including when an expired pass continues its current row.
    func measureWithin(_ budget: TimeInterval, jobs: [PremeasureJob], env: TextBuildEnvironment,
                       epoch: TranscriptPremeasureEpoch) -> [PremeasuredRow] {
        guard !self.active, self.pending.count == 0, let first = jobs.first,
              let job = self.prepared(first, env: env) else { return [] }
        let lease = UUID()
        self.lease = lease
        let result = TranscriptPremeasurer.shared.measureWithinPrepared(budget, jobs: [job], env: env, epoch: epoch) { [weak self] in
            self?.release(lease)
        }
        if result.completed {
            // The worker is already done. Release synchronously so back-to-back bounded passes
            // do not wait for a queued main callback; its stale lease ID cannot release a new job.
            self.lease = nil
        }
        return result.rows
    }
    private func release(_ lease: UUID) {
        guard self.lease == lease else {
            if !self.active { self.advance() }
            return
        }
        self.lease = nil
        self.advance()
    }
}

/// One cancellable weak capacity observation per denied driver, not a fixed-size global owner
/// registry. NotificationCenter removal is thread-safe; this wrapper removes even on deinit.
final class PremeasureCapacityObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    private let counter: PremeasureObservationCounter
    @MainActor init(service: TranscriptPremeasureAdmission, callback: @escaping @MainActor @Sendable () -> Void) {
        self.counter = service.observationCounter
        self.counter.value.withLock { $0 += 1 }
        self.token = NotificationCenter.default.addObserver(forName: TranscriptPremeasureAdmission.capacityReleased,
                                                            object: service, queue: .main) { _ in
            MainActor.assumeIsolated { callback() }
        }
    }
    deinit {
        NotificationCenter.default.removeObserver(self.token)
        self.counter.value.withLock { $0 -= 1 }
    }
}

final class PremeasureObservationCounter: Sendable {
    let value = Mutex(0)
}
