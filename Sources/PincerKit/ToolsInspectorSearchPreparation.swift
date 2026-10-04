import Foundation
import Observation
import Synchronization

public struct ToolsInspectorSearchResult: Sendable {
    public let groups: [InspectedToolGroup]
    public let summary: String
    public let totalCount: Int
    public let owner: UUID
    public let sourceRevision: Int
}

/// One active exact search plus one replaceable latest COW snapshot. No global cache.
@MainActor @Observable
public final class ToolsInspectorSearchPreparation {
    private final class Cancellation: Sendable {
        private let value = Mutex(false)
        var isCanceled: Bool { value.withLock { $0 } }
        func cancel() { value.withLock { $0 = true } }
    }
    private struct Job: Sendable {
        let cancellation: Cancellation
        let ticket: UUID
        let owner: UUID
        let sourceRevision: Int
        let inspection: ToolsInspection
        let filter: ToolFilter
        let query: String
        let server: String?
        let completion: @MainActor @Sendable (ToolsInspectorSearchResult?) -> Void
    }
    public private(set) var result: ToolsInspectorSearchResult?
    @ObservationIgnored private var current: UUID?
    @ObservationIgnored private var active: UUID?
    @ObservationIgnored private var pending: Job?
    #if DEBUG
    @ObservationIgnored package var probe: ToolsInspectorSearchProbe?
    @ObservationIgnored package var didPrepare: (@Sendable () async -> Void)?
    @ObservationIgnored package var workerTask: Task<Void, Never>?
    package var activeCount: Int { active == nil ? 0 : 1 }
    package var pendingCount: Int { pending == nil ? 0 : 1 }
    #endif
    public init() {}

    public func owns(_ owner: UUID, sourceRevision: Int) -> Bool {
        result?.owner == owner && result?.sourceRevision == sourceRevision
    }
    public func invalidate() {
        current = nil; result = nil
        let displaced = pending; pending = nil
        displaced?.completion(nil)
    }
    private func cancel(_ owner: UUID) {
        guard current == owner else { return }
        current = nil
        let displaced = pending; pending = nil
        displaced?.completion(nil)
        // Superseded query cancellation keeps the last finished same-source display.
    }
    public func prepare(_ inspection: ToolsInspection, filter: ToolFilter, query: String,
                        server: String? = nil, owner: UUID, sourceRevision: Int) async -> ToolsInspectorSearchResult? {
        guard !Task.isCancelled else { return nil }
        let ticket = UUID(), cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                current = ticket
                if result?.sourceRevision != sourceRevision { result = nil }
                let job = Job(cancellation: cancellation, ticket: ticket, owner: owner, sourceRevision: sourceRevision, inspection: inspection,
                    filter: filter, query: query, server: server, completion: { continuation.resume(returning: $0) })
                if active != nil {
                    let displaced = pending; pending = job
                    displaced?.completion(nil)
                } else { start(job) }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(ticket) }
        }
    }
    private func start(_ job: Job) {
        active = job.ticket
        #if DEBUG
        let probe = self.probe, didPrepare = self.didPrepare
        #endif
        let work = Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                #if DEBUG
                let groups = job.inspection.filtered(job.filter, search: job.query, observe: { probe?.record(match: $0) })
                #else
                let groups = job.inspection.filtered(job.filter, search: job.query)
                #endif
                let filtered: [InspectedToolGroup]
                if let server = job.server {
                    filtered = groups.compactMap { group in
                        let tools = group.tools.filter { $0.source == .mcp && $0.sourceDetail == server }
                        return tools.isEmpty ? nil : InspectedToolGroup(id: group.id, label: group.label, tools: tools)
                    }
                } else { filtered = groups }
                let output = ToolsInspectorSearchResult(groups: filtered, summary: job.inspection.summary,
                    totalCount: job.inspection.totalCount, owner: job.owner, sourceRevision: job.sourceRevision)
                #if DEBUG
                await didPrepare?()
                #endif
                return output
            }.value
            let accepted = current == job.ticket && !job.cancellation.isCanceled
            active = nil
            #if DEBUG
            workerTask = nil
            #endif
            if accepted { result = prepared }
            let next = pending; pending = nil
            if let next { start(next) }
            job.completion(accepted ? prepared : nil)
        }
        #if DEBUG
        workerTask = work
        #endif
    }
}
