import Foundation

// MARK: Model

/// Sessions for one Gateway (`GatewayStore.sessionManager`). Keeps its own `sessions.list` (the
/// sidebar's list leaves archived sessions out) and per-key previews, details and branches for the
/// page's lifetime; `sessions.changed` keeps them current.
@MainActor
@Observable
public final class SessionManagerModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue
    public typealias TranscriptChanged = @MainActor (_ key: String, _ change: SessionTranscriptChange) async -> Void

    public private(set) var rows: [SessionRow] = []
    public private(set) var filter: SessionManagerFilter = .active
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var loadError: String?

    public private(set) var previews: [String: SessionPreview] = [:]
    public private(set) var previewErrors: [String: String] = [:]
    public private(set) var details: [String: SessionRow] = [:]
    public private(set) var detailErrors: [String: String] = [:]
    public private(set) var branches: [String: [SessionBranch]] = [:]
    public private(set) var branchErrors: [String: String] = [:]
    public private(set) var rewindPoints: [String: [SessionRewindPoint]] = [:]
    public private(set) var rewindErrors: [String: String] = [:]

    /// Keys with a mutation in flight.
    public private(set) var busy: Set<String> = []
    /// A bulk action is running.
    public private(set) var isWorking = false
    public private(set) var lastMessage: String?
    public private(set) var actionError: String?
    /// Per-key failures of the last bulk action.
    public private(set) var lastFailures: [SessionBulkOutcome.Failure] = []
    /// Titles captured from the bulk action's immutable targets for failed rows.
    public private(set) var lastFailureTitles: [String: String] = [:]
    /// The message `sessions.rewind` cut, for the composer.
    public private(set) var lastEditorText: String?

    /// A call hit a scope error although the connection claimed `operator.admin`.
    public private(set) var deniedAdmin = false
    /// Methods the Gateway answered with unknown-method.
    public private(set) var rejectedMethods: Set<String> = []

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let scopes: @MainActor () -> [String]
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    // Optional, not `= {}` defaults: on Xcode 26.6 CI, awaiting these callbacks built from a sync closure
    // literal default argument corrupted the task allocator, while the same closures passed explicitly
    // didn't (#952). The toolchain root cause is unconfirmed; keep `= nil` and call with `?()`.
    @ObservationIgnored private let onTranscriptChanged: TranscriptChanged?
    @ObservationIgnored private let onSessionsChanged: (@MainActor () async -> Void)?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var previewsInFlight: Set<String> = []
    /// Only active detail requests retain ownership; terminal and invalidated entries are removed.
    @ObservationIgnored private var detailLoadOwners: [String: UUID] = [:]
    /// Bumped whenever a key's preview is dropped, so a reply already in flight is ignored.
    @ObservationIgnored private var previewGenerations: [String: Int] = [:]
    /// Ownership only for currently outstanding rewind loads; completed keys are removed.
    @ObservationIgnored private var rewindLoadOwners: [String: UUID] = [:]
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, allowsWritesWithoutAdmin: Bool,
         onTranscriptChanged: @escaping TranscriptChanged, onSessionsChanged: @escaping @MainActor () async -> Void)
    {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.onTranscriptChanged = onTranscriptChanged
        self.onSessionsChanged = onSessionsChanged
    }

    /// For checks and previews. `methods` is the advertised list (nil or empty when unknown).
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [GatewayConnection.adminScope] },
                allowsWritesWithoutAdmin: Bool = false,
                request: @escaping Request,
                onTranscriptChanged: TranscriptChanged? = nil,
                onSessionsChanged: (@MainActor () async -> Void)? = nil)
    {
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.onTranscriptChanged = onTranscriptChanged
        self.onSessionsChanged = onSessionsChanged
    }

    // MARK: Capability

    /// Whether the Gateway has `method`: advertised (or the list is unknown) and not rejected.
    public func supports(_ method: String) -> Bool {
        GatewayMethodSupport.supports(method, advertised: self.methods(), rejected: self.rejectedMethods)
    }

    public var supportsList: Bool { self.supports(SessionManager.listMethod) }
    public var supportsPreview: Bool { self.supports(SessionManager.previewMethod) }
    public var supportsDescribe: Bool { self.supports(SessionManager.describeMethod) }
    public var supportsBranches: Bool { self.supports(SessionManager.branchesListMethod) }
    public var supportsBranchSwitch: Bool { self.supports(SessionManager.branchesSwitchMethod) }
    public var supportsRewind: Bool { self.supports(SessionManager.rewindMethod) }
    public var supportsRecover: Bool { self.supports(SessionManager.recoverMethod) }
    public var supportsDelete: Bool { self.supports(SessionManager.deleteMethod) }
    public var supportsPatch: Bool { self.supports(SessionManager.patchMethod) }
    public var supportsPatchMany: Bool { self.supports(SessionManager.patchManyMethod) }
    public var supportsArchive: Bool { self.supportsPatchMany || self.supportsPatch }

    /// Full Management (or the demo).
    public var hasAdmin: Bool {
        if self.allowsWritesWithoutAdmin { return true }
        return !self.deniedAdmin && self.scopes().contains(GatewayConnection.adminScope)
    }

    public var canSwitchBranch: Bool { self.hasAdmin && self.supportsBranchSwitch }
    public var canRewind: Bool { self.hasAdmin && self.supportsRewind }
    public func canRecover(_ row: SessionRow) -> Bool { self.supportsRecover && SessionManager.isRecoverable(row) }

    public func deletePlan(_ keys: some Collection<String>) -> SessionDeletePlan {
        SessionManager.deletePlan(self.rows(for: keys), hasAdmin: self.hasAdmin)
    }

    // MARK: Reading

    public func visibleRows(search: String = "") -> [SessionRow] {
        SessionManager.filtered(self.rows, filter: self.filter, search: search)
    }

    public func row(_ key: String) -> SessionRow? {
        self.rows.first { $0.key == key } ?? self.details[key]
    }

    private func rows(for keys: some Collection<String>) -> [SessionRow] {
        let wanted = Set(keys)
        let listed = self.rows.filter { wanted.contains($0.key) }
        let listedKeys = Set(listed.map(\.key))
        return listed + wanted.subtracting(listedKeys).sorted().compactMap { self.details[$0] }
    }

    /// Loads `sessions.list` for `filter`.
    public func load(filter: SessionManagerFilter) async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.filter = filter
        self.isLoading = true
        self.loadError = nil
        defer { if generation == self.loadGeneration { self.isLoading = false } }
        do {
            let params: JSONValue = ["limit": .number(Double(SessionManager.listLimit)), "includeLastMessage": true,
                                     "archived": filter.listParam]
            let result = try await self.call(SessionManager.listMethod, params)
            guard generation == self.loadGeneration else { return }
            let next = result["sessions"]?.array?.compactMap(SessionRow.init) ?? []
            if next != self.rows { self.rows = next }
            self.hasLoaded = true
        } catch {
            guard generation == self.loadGeneration else { return }
            self.loadError = Self.message(error)
        }
    }

    public func loadIfNeeded(filter: SessionManagerFilter) async {
        if self.hasLoaded, self.filter == filter, self.loadError == nil { return }
        await self.load(filter: filter)
    }

    public func reload() async { await self.load(filter: self.filter) }

    /// `sessions.preview` for one key, once per page lifetime (until the session changes).
    public func loadPreview(key: String) async {
        guard self.supportsPreview, self.previews[key] == nil, self.previewsInFlight.insert(key).inserted else { return }
        let generation = self.previewGenerations[key, default: 0]
        defer { if self.previewGenerations[key, default: 0] == generation { self.previewsInFlight.remove(key) } }
        do {
            let result = try await self.call(SessionManager.previewMethod, [
                "keys": [.string(key)],
                "limit": .number(Double(SessionManager.previewItemLimit)),
                "maxChars": .number(Double(SessionManager.previewMaxChars)),
            ])
            // The session changed while this was in flight; a newer load owns the entry.
            guard self.previewGenerations[key, default: 0] == generation else { return }
            let preview = result["previews"]?.array?.compactMap(SessionPreview.init).first { $0.key == key }
                ?? SessionPreview(key: key, status: .missing, items: [])
            if self.previews[key] != preview { self.previews[key] = preview }
            self.previewErrors[key] = nil
        } catch {
            guard self.previewGenerations[key, default: 0] == generation else { return }
            self.previewErrors[key] = Self.message(error)
        }
    }

    /// Drops the cached preview and fetches it again (Refresh).
    public func reloadPreview(key: String) async {
        self.forgetPreview(key)
        await self.loadPreview(key: key)
    }

    /// `sessions.describe` for one key.
    public func loadDetails(key: String) async {
        guard !Task.isCancelled, self.supportsDescribe else { return }
        let owner = UUID()
        self.detailLoadOwners[key] = owner
        defer {
            if self.detailLoadOwners[key] == owner { self.detailLoadOwners[key] = nil }
        }
        var params: [String: JSONValue] = ["key": .string(key), "includeDerivedTitles": true, "includeLastMessage": true]
        if let agentId = self.row(key)?.raw["agentId"]?.text { params["agentId"] = .string(agentId) }
        do {
            let result = try await self.call(SessionManager.describeMethod, .object(params))
            guard !Task.isCancelled, self.detailLoadOwners[key] == owner else { return }
            if let row = result["session"].flatMap(SessionRow.init) {
                self.details[key] = row
                self.detailErrors[key] = nil
            } else {
                self.details[key] = nil
                self.detailErrors[key] = "This session is gone."
            }
        } catch {
            guard !Task.isCancelled, self.detailLoadOwners[key] == owner else { return }
            self.detailErrors[key] = Self.message(error)
        }
    }

    /// `sessions.branches.list` for one key.
    public func loadBranches(key: String) async {
        guard self.supportsBranches else { return }
        do {
            let result = try await self.call(SessionManager.branchesListMethod, .object(self.sessionKeyParams(key)))
            self.branches[key] = result["branches"]?.array?.compactMap(SessionBranch.init) ?? []
            self.branchErrors[key] = nil
        } catch {
            self.branchErrors[key] = Self.message(error)
        }
    }

    /// Recent user messages `sessions.rewind` can cut back to (`chat.history`).
    public func loadRewindPoints(key: String) async {
        guard self.supportsRewind, !Task.isCancelled else { return }
        let owner = UUID()
        self.rewindLoadOwners[key] = owner
        defer {
            if self.rewindLoadOwners[key] == owner { self.rewindLoadOwners[key] = nil }
        }
        do {
            let result = try await self.call(SessionManager.historyMethod, [
                "sessionKey": .string(key), "limit": .number(Double(SessionManager.rewindHistoryLimit)),
            ])
            guard self.rewindLoadOwners[key] == owner, !Task.isCancelled else { return }
            self.rewindPoints[key] = SessionRewindPoint.points(history: result)
            self.rewindErrors[key] = nil
        } catch {
            guard self.rewindLoadOwners[key] == owner, !Task.isCancelled else { return }
            self.rewindErrors[key] = Self.message(error)
        }
    }

    // MARK: Mutations

    /// Archives or unarchives `keys` with `sessions.patchMany` (in batches of 100), or one
    /// `sessions.patch` each when the Gateway doesn't have it.
    @discardableResult
    public func setArchived(_ keys: [String], archived: Bool) async -> SessionBulkOutcome {
        let targets = self.rows(for: keys)
        var outcome = SessionBulkOutcome()
        guard !targets.isEmpty else { return outcome }
        self.begin(targets.map(\.key))
        defer { self.end(targets.map(\.key)) }
        var remaining = targets
        if self.supportsPatchMany {
            remaining = []
            for batch in SessionManager.patchManyBatches(targets) {
                do {
                    let result = try await self.call(SessionManager.patchManyMethod,
                                                     SessionManager.patchManyParams(batch, archived: archived))
                    Self.collect(result, batch: batch, into: &outcome)
                } catch where AgentManagementError.classify(error) == .unsupported {
                    remaining += batch
                } catch {
                    let message = Self.message(error)
                    outcome.failed += batch.map { .init(key: $0.key, message: message) }
                }
            }
        }
        for row in remaining {
            do {
                _ = try await self.call(SessionManager.patchMethod, SessionManager.patchParams(row, archived: archived))
                outcome.succeeded.append(row.key)
            } catch {
                outcome.failed.append(.init(key: row.key, message: Self.message(error)))
            }
        }
        self.apply(archived: archived, to: Set(outcome.succeeded))
        let failureTitles = await Self.failureTitles(outcome.failed, targets: targets)
        self.finish(outcome, verb: archived ? "Archived" : "Unarchived", failureTitles: failureTitles)
        await self.onSessionsChanged?()
        return outcome
    }

    private static func collect(_ result: JSONValue, batch: [SessionRow], into outcome: inout SessionBulkOutcome) {
        var seen: Set<String> = []
        for entry in result["outcomes"]?.array ?? [] {
            guard let key = entry["key"]?.text else { continue }
            seen.insert(key)
            if entry["ok"]?.bool == true {
                outcome.succeeded.append(key)
            } else {
                outcome.failed.append(.init(key: key, message: entry["error"]?["message"]?.text ?? "Couldn't change this session."))
            }
        }
        for row in batch where !seen.contains(row.key) {
            outcome.failed.append(.init(key: row.key, message: "The Gateway didn't report this session."))
        }
    }

    /// Deletes `keys` and their transcripts. Archived rows go with `archivedOnly` (write scope); live
    /// rows need Full Management and are refused here without it.
    @discardableResult
    public func delete(_ keys: [String]) async -> SessionBulkOutcome {
        let targets = self.rows(for: keys)
        var outcome = SessionBulkOutcome()
        guard !targets.isEmpty else { return outcome }
        self.begin(targets.map(\.key))
        defer { self.end(targets.map(\.key)) }
        let hasAdmin = self.hasAdmin
        for row in targets {
            guard row.isArchived || hasAdmin else {
                outcome.failed.append(.init(key: row.key, message: SessionManager.mixedDeleteMessage))
                continue
            }
            do {
                let result = try await self.call(SessionManager.deleteMethod, SessionManager.deleteParams(row))
                if result["deleted"]?.bool == false {
                    outcome.failed.append(.init(key: row.key, message: "The Gateway didn't delete this session."))
                    continue
                }
                outcome.succeeded.append(row.key)
                self.forget(row.key)
                await self.onTranscriptChanged?(row.key, .deleted)
            } catch {
                outcome.failed.append(.init(key: row.key, message: Self.message(error)))
            }
        }
        let failureTitles = await Self.failureTitles(outcome.failed, targets: targets)
        self.finish(outcome, verb: "Deleted", failureTitles: failureTitles)
        await self.onSessionsChanged?()
        return outcome
    }

    /// Repoints the active transcript path to `leafEntryId` (admin).
    @discardableResult
    public func switchBranch(key: String, leafEntryId: String) async -> Bool {
        var params = self.sessionKeyParams(key)
        params["leafEntryId"] = .string(leafEntryId)
        return await self.mutateTranscript(key, SessionManager.branchesSwitchMethod, .object(params),
                                           success: "Switched branch") != nil
    }

    /// Cuts the active path back to before user message `entryId` (admin); the cut message's text is
    /// kept in `lastEditorText`.
    @discardableResult
    public func rewind(key: String, entryId: String) async -> Bool {
        var params = self.sessionKeyParams(key)
        params["entryId"] = .string(entryId)
        return await self.mutateTranscript(key, SessionManager.rewindMethod, .object(params),
                                           success: "Rewound the session") != nil
    }

    /// Recovers a restart-tombstoned session into a fresh one (`sessions.recover`, write scope).
    public func recover(key: String) async -> SessionRecoverResult? {
        self.begin([key])
        defer { self.end([key]) }
        var params: [String: JSONValue] = ["key": .string(key)]
        if let agentId = self.row(key)?.raw["agentId"]?.text { params["agentId"] = .string(agentId) }
        do {
            let response = try await self.call(SessionManager.recoverMethod, .object(params))
            guard let result = SessionRecoverResult(response) else {
                self.actionError = "The Gateway didn't return the recovered session."
                return nil
            }
            self.lastMessage = "Recovered the session"
            if let error = result.continuationError { self.actionError = error }
            self.forgetCaches(key)
            await self.onTranscriptChanged?(key, .changed(editorText: nil))
            await self.onSessionsChanged?()
            await self.reload()
            return result
        } catch {
            self.actionError = Self.message(error)
            return nil
        }
    }

    private func mutateTranscript(_ key: String, _ method: String, _ params: JSONValue, success: String) async -> JSONValue? {
        self.begin([key])
        defer { self.end([key]) }
        do {
            let result = try await self.call(method, params)
            self.lastMessage = success
            self.lastEditorText = method == SessionManager.rewindMethod ? result["editorText"]?.string : nil
            self.forgetCaches(key)
            await self.onTranscriptChanged?(key, .changed(editorText: self.lastEditorText))
            async let branches: Void = self.loadBranches(key: key)
            async let points: Void = self.loadRewindPoints(key: key)
            async let details: Void = self.loadDetails(key: key)
            _ = await (branches, points, details)
            return result
        } catch {
            self.actionError = Self.message(error)
            return nil
        }
    }

    public func clearMessages() {
        self.lastMessage = nil
        self.actionError = nil
        self.lastFailures = []
        self.lastFailureTitles = [:]
        self.lastEditorText = nil
    }

    // MARK: Events

    /// Keeps the list current from `sessions.changed` while it's loaded.
    func handleSessionsChanged(_ payload: JSONValue) {
        guard self.hasLoaded else { return }
        let reason = payload["reason"]?.text
        let key = payload["session"]?["key"]?.text ?? payload["sessionKey"]?.text ?? payload["key"]?.text
        if let key, reason == "delete" || reason == "deleted" {
            self.forget(key)
            return
        }
        if let key, let reason, SessionManager.transcriptChangingReasons.contains(reason) {
            self.forgetCaches(key)
        }
        guard let row = payload["session"].flatMap(SessionRow.init) else {
            self.scheduleReload()
            return
        }
        if let index = self.rows.firstIndex(where: { $0.key == row.key }) {
            let previous = self.rows[index]
            if previous.activityMs != row.activityMs { self.forgetPreview(row.key) }
            let merged = row.keepingPreview(of: previous)
            if merged != previous { self.rows[index] = merged }
        } else if self.filter.includes(row) {
            self.rows.append(row)
        }
        if self.details[row.key] != nil { self.details[row.key] = row }
    }

    func handleReconnect() {
        self.detailLoadOwners = [:]
        self.deniedAdmin = false
        self.rejectedMethods = []
        for key in Set(self.previews.keys).union(self.previewsInFlight) { self.previewGenerations[key, default: 0] += 1 }
        self.previewsInFlight = []
        self.previews = [:]
        self.previewErrors = [:]
        self.branches = [:]
        self.branchErrors = [:]
        self.rewindLoadOwners = [:]
        self.rewindPoints = [:]
        self.rewindErrors = [:]
        if self.hasLoaded { self.scheduleReload() }
    }

    private func scheduleReload() {
        self.reloadTask?.cancel()
        self.reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: Plumbing

    private func sessionKeyParams(_ key: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["sessionKey": .string(key)]
        if let agentId = self.row(key)?.raw["agentId"]?.text { params["agentId"] = .string(agentId) }
        return params
    }

    private func apply(archived: Bool, to keys: Set<String>) {
        guard !keys.isEmpty else { return }
        self.rows = self.rows.compactMap { row in
            guard keys.contains(row.key), case var .object(fields) = row.raw else { return row }
            fields["archived"] = .bool(archived)
            if !archived { fields["archivedAt"] = nil }
            guard let next = SessionRow(.object(fields)) else { return row }
            return self.filter.includes(next) ? next : nil
        }
    }

    private func forget(_ key: String) {
        self.detailLoadOwners[key] = nil
        self.rows.removeAll { $0.key == key }
        self.details[key] = nil
        self.detailErrors[key] = nil
        self.forgetCaches(key)
    }

    private func forgetCaches(_ key: String) {
        self.forgetPreview(key)
        self.rewindLoadOwners[key] = nil
        self.rewindPoints[key] = nil
        self.rewindErrors[key] = nil
    }

    /// Views reload a preview (and rewind points) whenever the entry goes missing.
    private func forgetPreview(_ key: String) {
        self.previewGenerations[key, default: 0] += 1
        self.previewsInFlight.remove(key)
        if self.previews[key] != nil { self.previews[key] = nil }
        if self.previewErrors[key] != nil { self.previewErrors[key] = nil }
    }

    func begin(_ keys: [String]) {
        self.clearMessages()
        self.busy.formUnion(keys)
        if keys.count > 1 { self.isWorking = true }
    }

    func end(_ keys: [String]) {
        self.busy.subtract(keys)
        if self.busy.isEmpty { self.isWorking = false }
    }

    private static func failureTitles(_ failures: [SessionBulkOutcome.Failure],
                                      targets: [SessionRow]) async -> [String: String] {
        guard !failures.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let failedKeys = Set(failures.map(\.key))
            var titles: [String: String] = [:]
            for row in targets where failedKeys.contains(row.key) {
                let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { titles[row.key] = title }
            }
            return titles
        }.value
    }

    private func finish(_ outcome: SessionBulkOutcome, verb: String, failureTitles: [String: String]) {
        self.lastFailures = outcome.failed
        self.lastFailureTitles = failureTitles
        if !outcome.succeeded.isEmpty || outcome.failed.isEmpty {
            self.lastMessage = SessionManager.bulkSummary(verb: verb, outcome)
        }
        if let first = outcome.failed.first {
            self.actionError = outcome.failed.count == 1 && outcome.succeeded.isEmpty
                ? first.message
                : "\(outcome.failed.count) \(outcome.failed.count == 1 ? "session" : "sessions") failed: \(first.message)"
        }
    }

    private func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        do {
            return try await self.request(method, params)
        } catch {
            switch AgentManagementError.classify(error) {
            case .needsAdmin: self.deniedAdmin = true
            case .unsupported: self.rejectedMethods.insert(method)
            default: break
            }
            throw error
        }
    }

    private static func message(_ error: Error) -> String {
        switch AgentManagementError.classify(error) {
        case .needsAdmin: SessionManager.needsAdminMessage
        case .unsupported: SessionManager.unsupportedMessage
        case let other: other.message
        }
    }
}
