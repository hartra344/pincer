import Foundation
import Observation

/// The Files tab for one chat session: files the session changed or read, the project tree and its artifacts
/// (`sessions.files.list`, `artifacts.list`; both `operator.read`). Listing parsing, flattening and filtering run
/// off-main; the main actor only assigns a finished `SessionFilesSnapshot`. Get one per chat from
/// `GatewayStore.filesModel(for:)`.
@MainActor
@Observable
public final class SessionFilesModel {
    public typealias Request = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public nonisolated static let listMethod = "sessions.files.list"
    public nonisolated static let getMethod = "sessions.files.get"
    public nonisolated static let setMethod = "sessions.files.set"
    public nonisolated static let artifactsMethod = "artifacts.list"
    /// `@AppStorage` key for "Show Files in the workspace panel". Defaults to ON.
    public static let showInPanelKey = "pincer.showFilesInWorkspacePanel"
    /// Upstream's `WORKSPACE_PREVIEW_MAX_BYTES`: files over this are neither previewed nor saved.
    public nonisolated static let maxPreviewBytes = 256 * 1024

    public let sessionKey: String
    public let agentId: String?
    public private(set) var snapshot = SessionFilesSnapshot()
    /// A listing has been applied (cached data shows at once; this is false only before the first reply).
    public private(set) var loaded = false
    public private(set) var isLoading = false
    /// The last listing failed. Cached rows stay visible.
    public private(set) var error: SessionFilesError?
    public var filter: SessionFilesFilter = .all { didSet { if oldValue != self.filter { self.rebuild() } } }
    /// Typing filters locally now and asks the Gateway after a short pause.
    public private(set) var search = ""

    /// Editing needs `operator.admin` (the demo counts as Full Management).
    public var hasAdmin: Bool { self.adminCheck() }
    /// The Gateway advertises `sessions.files.list`. Hide the tab when false.
    public var isAvailable: Bool { self.advertisedCheck(Self.listMethod) }
    public var canEdit: Bool { self.hasAdmin && self.advertisedCheck(Self.setMethod) }

    @ObservationIgnored let request: Request
    @ObservationIgnored let adminCheck: @MainActor () -> Bool
    @ObservationIgnored let advertisedCheck: @MainActor (String) -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var list = SessionFilesParser.List()
    @ObservationIgnored private var searchList: SessionFilesParser.List?
    @ObservationIgnored private var artifacts: [SessionArtifactItem] = []
    @ObservationIgnored private var omittedOversized = false
    @ObservationIgnored private var children: [String: [SessionFileTreeEntry]] = [:]
    @ObservationIgnored private var expanded: Set<String> = []
    @ObservationIgnored private var loadingFolders: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var buildGeneration = 0
    @ObservationIgnored private var viewers: Set<AnyHashable> = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pendingReload = false

    public init(sessionKey: String, agentId: String? = nil, request: @escaping Request,
                hasAdmin: @escaping @MainActor () -> Bool = { true },
                advertises: @escaping @MainActor (String) -> Bool = { _ in true },
                debounce: Duration = .milliseconds(250)) {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.request = request
        self.adminCheck = hasAdmin
        self.advertisedCheck = advertises
        self.debounce = debounce
    }

    // MARK: Visibility and refresh

    /// The panel shows (or stops showing) the Files tab. Becoming visible refreshes, which also catches runs that
    /// ended while hidden. Several windows may show it: it counts as visible while any viewer is.
    public func setVisible(_ visible: Bool, viewer: AnyHashable) {
        if visible {
            let first = self.viewers.isEmpty
            self.viewers.insert(viewer)
            if first || self.dirty { self.requestRefresh() }
        } else {
            self.viewers.remove(viewer)
        }
    }

    /// A terminal chat event (final, error, aborted) landed for this session: files may have changed.
    /// Refreshes now when visible, otherwise on next show.
    public func runEnded() {
        if self.viewers.isEmpty { self.dirty = true } else { self.requestRefresh() }
    }

    /// Re-lists the root (or the search) and the artifacts. Safe to call often; calls coalesce.
    public func refresh() async {
        if let running = self.refreshTask {
            // A trigger that lands mid-flight (run ended, save) needs one more reload after this one.
            self.pendingReload = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                self.pendingReload = false
                await self.load()
            } while self.pendingReload
            // Cleared in the same main-actor step as the last pendingReload check, so no trigger slips between them.
            self.refreshTask = nil
        }
        self.refreshTask = task
        await task.value
    }

    private func requestRefresh() {
        Task { await self.refresh() }
    }

    /// A reconnect keeps what's shown (cached rows first, then refresh): drops in-flight replies and re-lists.
    public func handleReconnect() {
        self.generation += 1
        self.refreshTask = nil
        self.pendingReload = false
        self.isLoading = false
        if self.viewers.isEmpty { self.dirty = true } else { self.requestRefresh() }
    }

    /// Forgets everything (session reset, cache eviction).
    public func reset() {
        self.generation += 1
        self.searchTask?.cancel()
        self.refreshTask = nil
        self.list = .init()
        self.searchList = nil
        self.artifacts = []
        self.omittedOversized = false
        self.children = [:]
        self.expanded = []
        self.loadingFolders = []
        self.snapshot = SessionFilesSnapshot()
        self.loaded = false
        self.isLoading = false
        self.error = nil
        self.dirty = false
    }

    // MARK: Search and folders

    public func setSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != self.search else { return }
        self.search = trimmed
        self.searchTask?.cancel()
        self.rebuild()
        if trimmed.isEmpty {
            self.searchList = nil
            self.rebuild()
            return
        }
        let generation = self.generation
        self.searchTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.runSearch(trimmed, generation: generation)
        }
    }

    /// Expands or collapses a folder; fetches its children the first time.
    public func toggleFolder(_ path: String) {
        if self.expanded.contains(path) {
            self.expanded.remove(path)
            self.rebuild()
            return
        }
        self.expanded.insert(path)
        guard self.children[path] == nil else {
            self.rebuild()
            return
        }
        self.loadingFolders.insert(path)
        self.rebuild()
        let generation = self.generation
        Task {
            let result = try? await self.fetchList(path: path, search: "")
            guard generation == self.generation else { return }
            self.loadingFolders.remove(path)
            if let result { self.children[path] = result.entries }
            self.rebuild()
        }
    }

    // MARK: Documents

    /// Opens a file for the viewer or editor. Hold the result in `@State`.
    public func open(path: String, name: String? = nil) -> SessionFileDocument {
        SessionFileDocument(path: path, name: name ?? (path as NSString).lastPathComponent, model: self)
    }

    /// An artifact's image or download goes through the existing artifact loader; see `SessionArtifactItem.id`.
    func fileSaved() { self.requestRefresh() }

    // MARK: Loading

    private func baseParams(path: String? = nil, search: String? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["sessionKey": .string(self.sessionKey)]
        if let agentId, !agentId.isEmpty { params["agentId"] = .string(agentId) }
        if let path { params["path"] = .string(path) }
        if let search { params["search"] = .string(search) }
        return .object(params)
    }

    func fileParams(path: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["sessionKey": .string(self.sessionKey), "path": .string(path)]
        if let agentId, !agentId.isEmpty { params["agentId"] = .string(agentId) }
        return params
    }

    private func fetchList(path: String, search: String) async throws -> SessionFilesParser.List {
        let params = self.baseParams(path: path, search: search)
        let request = self.request
        return try await Task.detached(priority: .userInitiated) {
            SessionFilesParser.list(try await request(Self.listMethod, params))
        }.value
    }

    private func load() async {
        guard self.isAvailable else {
            self.error = .unsupported
            return
        }
        let generation = self.generation
        self.dirty = false
        self.isLoading = true
        let request = self.request
        let listParams = self.baseParams(path: "", search: self.search.isEmpty ? "" : self.search)
        var artifactParams: [String: JSONValue] = ["sessionKey": .string(self.sessionKey)]
        if let agentId, !agentId.isEmpty { artifactParams["agentId"] = .string(agentId) }
        let artifactsPayload = JSONValue.object(artifactParams)
        async let listed = Task.detached(priority: .userInitiated) { () -> Result<SessionFilesParser.List, Error> in
            do { return .success(SessionFilesParser.list(try await request(Self.listMethod, listParams))) } catch { return .failure(error) }
        }.value
        async let artifactsResult = Task.detached(priority: .userInitiated) { () -> (items: [SessionArtifactItem], omittedOversized: Bool)? in
            guard let value = try? await request(Self.artifactsMethod, artifactsPayload) else { return nil }
            return SessionFilesParser.artifacts(value)
        }.value
        let (listResult, artifactResult) = await (listed, artifactsResult)
        guard generation == self.generation else { return }
        self.isLoading = false
        switch listResult {
        case let .success(parsed):
            if self.search.isEmpty { self.list = parsed } else { self.searchList = parsed }
            self.error = nil
            self.loaded = true
        case let .failure(failure):
            self.error = SessionFilesError.map(failure)
        }
        // A failing artifacts call just hides that group; the listing is the tab's core.
        if let artifactResult {
            self.artifacts = artifactResult.items
            self.omittedOversized = artifactResult.omittedOversized
        }
        self.rebuild()
        // Keep open folders fresh after the root reload.
        for path in self.expanded where self.search.isEmpty {
            self.refetchFolder(path, generation: generation)
        }
    }

    private func refetchFolder(_ path: String, generation: Int) {
        Task {
            guard let result = try? await self.fetchList(path: path, search: "") else { return }
            guard generation == self.generation else { return }
            self.children[path] = result.entries
            self.rebuild()
        }
    }

    private func runSearch(_ query: String, generation: Int) async {
        guard generation == self.generation, query == self.search else { return }
        do {
            let result = try await self.fetchList(path: "", search: query)
            guard generation == self.generation, query == self.search else { return }
            self.searchList = result
            self.error = nil
        } catch {
            guard generation == self.generation, query == self.search else { return }
            self.error = SessionFilesError.map(error)
        }
        self.rebuild()
    }

    // MARK: Snapshot

    private struct BuildInput: Sendable {
        var list: SessionFilesParser.List
        var searchList: SessionFilesParser.List?
        var artifacts: [SessionArtifactItem]
        var omitted: Bool
        var children: [String: [SessionFileTreeEntry]]
        var expanded: Set<String>
        var loading: Set<String>
        var search: String
        var filter: SessionFilesFilter
    }

    private func rebuild() {
        self.buildGeneration += 1
        let token = self.buildGeneration
        let input = BuildInput(list: self.list, searchList: self.searchList, artifacts: self.artifacts,
                               omitted: self.omittedOversized, children: self.children, expanded: self.expanded,
                               loading: self.loadingFolders, search: self.search, filter: self.filter)
        Task.detached(priority: .userInitiated) {
            let next = Self.build(input)
            await MainActor.run {
                guard token == self.buildGeneration else { return }
                self.snapshot = next
            }
        }
    }

    private nonisolated static func build(_ input: BuildInput) -> SessionFilesSnapshot {
        var snap = SessionFilesSnapshot()
        // While a search is pending, the cached listing is filtered locally; the Gateway's answer then replaces it.
        let source = input.searchList ?? input.list
        snap.root = input.list.root ?? source.root
        snap.gitCheckout = input.list.gitCheckout ?? source.gitCheckout
        let query = input.search
        let files = input.list.files.filter { SessionFilesParser.matches($0.path, query) }
        let changed = files.filter { $0.kind == .modified }
        let read = files.filter { $0.kind == .read }
        let artifacts = input.artifacts.filter { SessionFilesParser.matches($0.title, query) }
        snap.counts = .init(changed: changed.count, read: read.count, artifacts: artifacts.count)
        snap.artifactsOmittedOversized = input.omitted
        switch input.filter {
        case .all:
            snap.changed = changed
            snap.read = read
            snap.artifacts = artifacts
            let treeSource: [SessionFileTreeEntry]
            if query.isEmpty { treeSource = input.list.entries } else { treeSource = input.searchList?.entries ?? [] }
            snap.tree = SessionFilesParser.flatten(root: treeSource, children: input.children, expanded: input.expanded,
                                                   loading: input.loading, search: query)
            snap.treeTruncated = (query.isEmpty ? input.list : input.searchList)?.truncated ?? false
            snap.treeEntryCount = treeSource.count
        case .changed: snap.changed = changed
        case .read: snap.read = read
        case .artifacts: snap.artifacts = artifacts
        }
        return snap
    }
}
