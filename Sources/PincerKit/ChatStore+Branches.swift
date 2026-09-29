import Foundation

extension ChatStore {
    /// `sessions.branches.list` is advertised (or the Gateway doesn't list its methods).
    public var canListBranches: Bool { self.gateway?.sessionManager.supportsBranches == true }

    /// Switching needs `sessions.branches.switch` and `operator.admin`, like the Session Manager.
    public var canSwitchBranches: Bool { self.gateway?.sessionManager.canSwitchBranch == true }

    /// This chat's transcript tips, active first, once there is more than one to choose from.
    public var hasBranches: Bool { self.branches.count > 1 }

    /// 1-based position of the active branch among `branches`, for "Branch 1 of 2".
    public var activeBranchNumber: Int? {
        self.branches.firstIndex { $0.active }.map { $0 + 1 }
    }

    /// Reloads `branches` (`sessions.branches.list`, read scope). Failures leave the list empty:
    /// branches are an extra, never an error banner.
    public func refreshBranches() async {
        guard !self.headless, let gateway, gateway.state.isConnected, self.canListBranches else {
            if !self.branches.isEmpty { self.branches = [] }
            return
        }
        var params = self.params(keyName: "sessionKey")
        do {
            let result = try await gateway.connection.request(SessionManager.branchesListMethod, .object(params), timeout: 15)
            let list = result["branches"]?.array?.compactMap(SessionBranch.init) ?? []
            if list != self.branches { self.branches = list }
        } catch is CancellationError {
            return
        } catch {
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
