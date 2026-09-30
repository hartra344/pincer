import Foundation

extension ChatStore {
    /// `sessions.branches.list` is advertised (or the Gateway doesn't list its methods).
    public var canListBranches: Bool { self.gateway?.sessionManager.supportsBranches == true }

    /// Switching needs `sessions.branches.switch` and `operator.admin`, like the Session Manager.
    public var canSwitchBranches: Bool { self.gateway?.sessionManager.canSwitchBranch == true && !self.isBusyForHistoryChange }

    /// Oldest first (`updatedAt` ascending, unknown last, ties by leaf id): stable whichever branch is active.
    static func orderedBranches(_ list: [SessionBranch]) -> [SessionBranch] {
        list.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.leafEntryId < rhs.leafEntryId
            }
        }
    }

    /// This chat's transcript tips in a stable order, once there is more than one to choose from.
    public var hasBranches: Bool { self.branches.count > 1 }

    /// 1-based position of the active branch among `branches`, for "Branch 1 of 2".
    public var activeBranchNumber: Int? {
        self.branches.firstIndex { $0.active }.map { $0 + 1 }
    }

    /// The message whose footer carries the branch switcher. `sessions.branches.list` reports only
    /// branch tips, not where they fork, so this is the message the latest Edit & Resend or Regenerate
    /// sent while it's on the active path, else the last committed user message. Nil without branches.
    public var branchAnchorId: String? {
        guard self.hasBranches else { return nil }
        let users = self.items.filter { $0.role == .user && $0.isReplyable && $0.transcriptId != nil }
        if let key = self.branchAnchorKey, let anchor = users.last(where: { $0.idempotencyKey == key }) {
            return anchor.transcriptId
        }
        return users.last?.transcriptId
    }

    /// Records whether the anchor row is on screen; a no-op unless it changed.
    public func setBranchAnchorVisible(_ visible: Bool) {
        if self.isBranchAnchorVisible != visible { self.isBranchAnchorVisible = visible }
    }

    /// The header chip's content, or nil while there's nothing to show (no branches, or the inline switcher is on screen).
    public var branchHeaderChip: BranchHeaderChip? {
        BranchHeaderChip(branches: self.branches, anchorVisible: self.isBranchAnchorVisible,
                         canSwitch: self.canSwitchBranches && !self.isRunning)
    }

    /// Scrolls the transcript to the message where branches fork.
    public func showForkPoint() { self.showForkPointHandler?() }

    /// Reloads `branches` (`sessions.branches.list`, read scope). Failures leave the list empty:
    /// branches are an extra, never an error banner. Overlapping calls apply only the newest
    /// response; an older caller returns once that one has landed.
    public func refreshBranches() async {
        self.branchRefreshGeneration += 1
        let generation = self.branchRefreshGeneration
        let task = Task { await self.fetchBranches(generation) }
        self.branchRefreshTask = task
        await task.value
        if generation != self.branchRefreshGeneration { await self.branchRefreshTask?.value }
    }

    private func fetchBranches(_ generation: Int) async {
        guard !self.headless, let gateway, gateway.state.isConnected, self.canListBranches else {
            if generation == self.branchRefreshGeneration, !self.branches.isEmpty { self.branches = [] }
            return
        }
        let params = self.params(keyName: "sessionKey")
        do {
            let result = try await gateway.connection.request(SessionManager.branchesListMethod, .object(params), timeout: 15)
            guard generation == self.branchRefreshGeneration else { return }
            let list = Self.orderedBranches(result["branches"]?.array?.compactMap(SessionBranch.init) ?? [])
            if list != self.branches { self.branches = list }
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.branchRefreshGeneration else { return }
            if !self.branches.isEmpty { self.branches = [] }
        }
    }

    /// Makes `leafEntryId` the active path (`sessions.branches.switch`, admin), then reloads the
    /// transcript. On failure `errorMessage` says why and nothing else changes.
    @discardableResult
    public func switchBranch(to leafEntryId: String) async -> Bool {
        guard let gateway, self.canSwitchBranches, !self.isRunning,
              self.branches.contains(where: { $0.leafEntryId == leafEntryId && !$0.active }) else { return false }
        var params = self.params(keyName: "sessionKey")
        params["leafEntryId"] = .string(leafEntryId)
        do {
            _ = try await gateway.connection.request(SessionManager.branchesSwitchMethod, .object(params), timeout: 30)
        } catch {
            self.errorMessage = L("Couldn’t switch branch: \(error.localizedDescription)")
            return false
        }
        self.editTarget = nil
        await gateway.transcriptChanged(key: self.sessionKey, change: .changed(editorText: nil))
        await self.refreshBranches()
        return true
    }
}

/// One branch in the footer switcher and the header chip's menu.
public struct BranchMenuEntry: Equatable, Sendable {
    public let leafEntryId: String
    public let title: String
    public let isActive: Bool

    /// "Title · N messages".
    public static func title(for branch: SessionBranch) -> String {
        [branch.title, L("\(String(branch.messageCount)) messages")].joined(separator: " · ")
    }
}

/// The "Branch 2 of 3" chip shown in the chat header while the inline switcher is scrolled away.
public struct BranchHeaderChip: Equatable, Sendable {
    public let label: String
    public let entries: [BranchMenuEntry]
    /// Switching is possible: admin scope and no run in flight.
    public let canSwitch: Bool

    public init?(branches: [SessionBranch], anchorVisible: Bool, canSwitch: Bool) {
        guard branches.count > 1, !anchorVisible, let active = branches.firstIndex(where: \.active) else { return nil }
        self.label = L("Branch \(active + 1) of \(branches.count)")
        self.entries = branches.map {
            BranchMenuEntry(leafEntryId: $0.leafEntryId, title: BranchMenuEntry.title(for: $0), isActive: $0.active)
        }
        self.canSwitch = canSwitch
    }
}
