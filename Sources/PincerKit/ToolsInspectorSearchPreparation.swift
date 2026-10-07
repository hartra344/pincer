import Foundation
import Observation

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
    public private(set) var result: ToolsInspectorSearchResult?
    /// Bumped whenever `result` is cleared, so an output resumed after the clear is not republished.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private let preparer = LatestWinsPreparer<ToolsInspectorSearchResult>()
    #if DEBUG
    @ObservationIgnored package var probe: ToolsInspectorSearchProbe?
    @ObservationIgnored package var didPrepare: (@Sendable () async -> Void)?
    package var workerTask: Task<Void, Never>? { preparer.workerTask }
    package var activeCount: Int { preparer.activeCount }
    package var pendingCount: Int { preparer.pendingCount }
    #endif
    public init() {}

    public func owns(_ owner: UUID, sourceRevision: Int) -> Bool {
        result?.owner == owner && result?.sourceRevision == sourceRevision
    }
    public func invalidate() {
        result = nil
        epoch &+= 1
        preparer.invalidate()
    }
    public func prepare(_ inspection: ToolsInspection, filter: ToolFilter, query: String,
                        server: String? = nil, owner: UUID, sourceRevision: Int) async -> ToolsInspectorSearchResult? {
        guard !Task.isCancelled else { return nil }
        if result?.sourceRevision != sourceRevision { result = nil; epoch &+= 1 }
        let epoch = self.epoch
        // A superseded query's cancellation keeps the last finished same-source display.
        let output = await preparer.prepare(start: {
            #if DEBUG
            let probe = self.probe, didPrepare = self.didPrepare
            #endif
            return {
                #if DEBUG
                let groups = inspection.filtered(filter, search: query, observe: { probe?.record(match: $0) })
                #else
                let groups = inspection.filtered(filter, search: query)
                #endif
                let filtered: [InspectedToolGroup]
                if let server {
                    filtered = groups.compactMap { group in
                        let tools = group.tools.filter { $0.source == .mcp && $0.sourceDetail == server }
                        return tools.isEmpty ? nil : InspectedToolGroup(id: group.id, label: group.label, tools: tools)
                    }
                } else { filtered = groups }
                let output = ToolsInspectorSearchResult(groups: filtered, summary: inspection.summary,
                    totalCount: inspection.totalCount, owner: owner, sourceRevision: sourceRevision)
                #if DEBUG
                await didPrepare?()
                #endif
                return output
            }
        })
        if let output, epoch == self.epoch { result = output }
        return output
    }
}
