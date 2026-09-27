import CryptoKit
import Foundation

// Agent management (`agents.create/update/delete`, `agent.identity.get`) and workspace bootstrap
// files (`agents.files.list/get/set`). Writes need `operator.admin` (Full Management); reads need
// `operator.read`. The Gateway sends no event when agents change, so every mutation re-fetches
// `agents.list`.

// MARK: Constants and pure logic

public enum AgentManagement {
    public static let createMethod = "agents.create"
    public static let updateMethod = "agents.update"
    public static let deleteMethod = "agents.delete"
    public static let identityMethod = "agent.identity.get"
    public static let filesListMethod = "agents.files.list"
    public static let filesGetMethod = "agents.files.get"
    public static let filesSetMethod = "agents.files.set"

    /// The Gateway's cap on one workspace file (`MAX_WORKSPACE_BOOTSTRAP_FILE_BYTES`), in UTF-8 bytes.
    public static let maxFileBytes = 2 * 1024 * 1024
    /// The files `agents.files.get/set` accept (`WORKSPACE_BOOTSTRAP_FILENAMES`). The Gateway's
    /// `agents.files.list` decides which ones Pincer offers.
    public static let allowedFileNames: Set<String> = [
        "AGENTS.md", "SOUL.md", "IDENTITY.md", "USER.md", "BOOTSTRAP.md", "MEMORY.md",
    ]
    /// Ids the Gateway keeps for its own system agents.
    public static let reservedIds: Set<String> = ["openclaw", "crestodian"]
    public static let conflictErrorType = "agent_file_conflict"

    public static let needsAdminMessage = "Editing agents needs Full Management. Turn it on under Connection, then approve this device on the Gateway host."
    public static let unsupportedMessage = "This gateway can't manage agents. Update OpenClaw to create and edit agents here."
    public static let workspaceChangeWarning = "Changing the workspace points this agent at a different folder. Files aren't moved."
    public static let bindingsNotCopiedNote = "Channel bindings aren't copied. The copy gets its own new workspace."

    /// The id the Gateway derives from an agent name (`normalizeAgentIdStrict`), or nil when the
    /// name has no usable characters.
    public static func agentId(forName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: [.regularExpression, .caseInsensitive]) != nil {
            return lower
        }
        var id = lower.replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
        id = id.replacingOccurrences(of: "^-+", with: "", options: .regularExpression)
        id = id.replacingOccurrences(of: "-+$", with: "", options: .regularExpression)
        id = String(id.prefix(64))
        return id.isEmpty ? nil : id
    }

    /// "Scout Copy", then "Scout Copy 2"… whichever isn't taken (by name or by derived id).
    public static func duplicateName(for name: String, existing: [AgentSummary]) -> String {
        let names = Set(existing.map { $0.name.lowercased() })
        let ids = Set(existing.map(\.id))
        func free(_ candidate: String) -> Bool {
            !names.contains(candidate.lowercased()) && !(self.agentId(forName: candidate).map(ids.contains) ?? false)
        }
        let base = "\(name) Copy"
        if free(base) { return base }
        var n = 2
        while !free("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Lowercase SHA-256 hex of the UTF-8 bytes, the Gateway's file `hash`.
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func byteCount(_ text: String) -> Int { text.utf8.count }

    /// "2 MB", "1.4 MB", "12 KB".
    public static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    public static func tooLargeMessage(bytes: Int) -> String {
        "File is larger than the \(self.formatBytes(self.maxFileBytes)) limit (\(self.formatBytes(bytes)))."
    }

    /// The delete confirmation's message. `bindingCount` is nil when the config isn't loaded.
    public static func deleteMessage(agentName: String, bindingCount: Int?) -> String {
        let bindings = bindingCount.map { " and its \($0) binding\($0 == 1 ? "" : "s")" } ?? ""
        return "This removes “\(agentName)” from the gateway\(bindings). Delete Agent keeps its workspace, sessions and other data on the gateway host. Delete and Move Files to Trash moves them to the host's Trash."
    }

    /// The agent's own model override in the config (`agents.entries.<id>.model`, a ref or
    /// `{primary}`): "" when it uses the Gateway default, nil when the config isn't loaded.
    /// (`agents.list` reports the effective model, so it can't tell the two apart.)
    public static func configuredModel(agentId: String, in config: JSONValue?) -> String? {
        guard let config, config["agents"] != nil else { return nil }
        let model = config["agents"]?["entries"]?[agentId]?["model"]
        return model?.text ?? model?["primary"]?.text ?? ""
    }

    /// Routing bindings (config `bindings[]`) that point at an agent.
    public static func bindings(for agentId: String, in config: JSONValue?) -> [AgentBinding] {
        (config?["bindings"]?.array ?? []).enumerated().compactMap { index, raw in
            guard raw["agentId"]?.text == agentId else { return nil }
            return AgentBinding(index: index, raw: raw)
        }
    }
}

/// One routing binding (`bindings[]` in the config) for an agent. Read only here.
public struct AgentBinding: Identifiable, Hashable, Sendable {
    public let index: Int
    public let raw: JSONValue
    public var id: Int { self.index }

    /// "telegram · account work · peer 12345", from the `match` object.
    public var summary: String {
        guard let match = self.raw["match"]?.object, !match.isEmpty else { return "All messages" }
        let order = ["channel", "accountId", "peer", "guildId", "teamId", "roles"]
        let keys = match.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return keys.map { key in
            let value = match[key] ?? .null
            let text: String
            if let string = value.text {
                text = string
            } else if let object = value.object {
                text = [object["kind"]?.text, object["id"]?.text].compactMap(\.self).joined(separator: " ")
            } else {
                text = value.compactString()
            }
            return key == "channel" ? text : "\(Self.label(key)) \(text)"
        }.joined(separator: " · ")
    }

    private static func label(_ key: String) -> String {
        switch key {
        case "accountId": "account"
        case "guildId": "server"
        case "teamId": "team"
        default: key
        }
    }
}

// MARK: Drafts

/// The editable fields of an agent: the create, edit and duplicate forms.
public struct AgentDraft: Hashable, Sendable {
    public var name: String
    public var emoji: String
    public var avatar: String
    /// A model ref (`provider/model`); empty uses the Gateway default.
    public var model: String
    /// Empty lets the Gateway pick (create) or keeps the current one (edit).
    public var workspace: String

    public init(name: String = "", emoji: String = "", avatar: String = "", model: String = "", workspace: String = "") {
        self.name = name
        self.emoji = emoji
        self.avatar = avatar
        self.model = model
        self.workspace = workspace
    }

    /// `configuredModel` is the agent's own override ("" for the Gateway default); nil falls back
    /// to the effective model from `agents.list`.
    public init(_ agent: AgentSummary, configuredModel: String? = nil) {
        self.init(name: agent.name, emoji: agent.emoji ?? "", avatar: agent.avatar ?? "",
                  model: configuredModel ?? agent.model ?? "", workspace: agent.workspace ?? "")
    }

    /// The Create sheet for duplicating `agent`: "<Name> Copy", same identity and model, and a
    /// blank workspace so the Gateway makes a new one.
    public static func duplicate(of agent: AgentSummary, existing: [AgentSummary]) -> AgentDraft {
        var draft = AgentDraft(agent)
        draft.name = AgentManagement.duplicateName(for: agent.name, existing: existing)
        draft.workspace = ""
        return draft
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var trimmedName: String { Self.trim(self.name) }

    /// The id the Gateway will give a new agent with this name.
    public var derivedId: String? { AgentManagement.agentId(forName: self.trimmedName) }

    /// Why the form can't be sent, or nil.
    public var validationError: String? {
        let name = self.trimmedName
        if name.isEmpty { return "Enter a name." }
        guard let id = self.derivedId else { return "Use at least one letter a–z or digit in the name." }
        if AgentManagement.reservedIds.contains(id) { return "“\(id)” is reserved by OpenClaw." }
        if self.name.contains(where: \.isNewline) { return "The name must be one line." }
        if Self.trim(self.emoji).count > 1 { return "Use a single emoji." }
        return nil
    }

    /// Also checks the id isn't already an agent.
    public func validationError(existing: [AgentSummary]) -> String? {
        if let error = self.validationError { return error }
        if let id = self.derivedId, existing.contains(where: { $0.id == id }) {
            return "An agent with the id “\(id)” already exists."
        }
        return nil
    }

    /// `agents.create` params: only non-empty optional fields.
    public var createParams: JSONValue {
        var params: [String: JSONValue] = ["name": .string(self.trimmedName)]
        for (key, value) in [("workspace", self.workspace), ("model", self.model), ("emoji", self.emoji), ("avatar", self.avatar)] {
            let trimmed = Self.trim(value)
            if !trimmed.isEmpty { params[key] = .string(trimmed) }
        }
        return .object(params)
    }

    /// `agents.update` params with only the fields that changed from `original`, or nil when none
    /// did. A cleared model sends `null` (back to the Gateway default); a cleared workspace is
    /// left alone (the Gateway can't unset it). Emoji and avatar may be cleared with "".
    public func updateParams(agentId: String, from original: AgentDraft) -> JSONValue? {
        var params: [String: JSONValue] = [:]
        let name = self.trimmedName
        if name != original.trimmedName, !name.isEmpty { params["name"] = .string(name) }
        let workspace = Self.trim(self.workspace)
        if workspace != Self.trim(original.workspace), !workspace.isEmpty { params["workspace"] = .string(workspace) }
        let model = Self.trim(self.model)
        if model != Self.trim(original.model) { params["model"] = model.isEmpty ? .null : .string(model) }
        let emoji = Self.trim(self.emoji)
        if emoji != Self.trim(original.emoji) { params["emoji"] = .string(emoji) }
        let avatar = Self.trim(self.avatar)
        if avatar != Self.trim(original.avatar) { params["avatar"] = .string(avatar) }
        guard !params.isEmpty else { return nil }
        params["agentId"] = .string(agentId)
        return .object(params)
    }

    /// Whether saving would point the agent at a different workspace folder.
    public func changesWorkspace(from original: AgentDraft) -> Bool {
        let workspace = Self.trim(self.workspace)
        return !workspace.isEmpty && workspace != Self.trim(original.workspace)
    }
}

// MARK: Results

/// One entry of `agents.files.list` / `get` / `set`.
public struct AgentFileEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let missing: Bool
    /// Absence is normal (optional profile files, MEMORY.md before anything is written).
    public let expectedAbsent: Bool
    public let size: Int?
    public let updatedAt: Date?
    public let hash: String?
    public let content: String?

    public var id: String { self.name }

    public init?(_ json: JSONValue) {
        guard let name = json["name"]?.text else { return nil }
        self.name = name
        self.path = json["path"]?.text ?? name
        self.missing = json["missing"]?.bool ?? false
        self.expectedAbsent = json["expectedAbsent"]?.bool ?? false
        self.size = json["size"]?.int
        self.updatedAt = json["updatedAtMs"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.hash = json["hash"]?.text?.lowercased()
        self.content = json["content"]?.string
    }

    public init(name: String, path: String? = nil, missing: Bool = false, expectedAbsent: Bool = false,
                size: Int? = nil, updatedAt: Date? = nil, hash: String? = nil, content: String? = nil)
    {
        self.name = name
        self.path = path ?? name
        self.missing = missing
        self.expectedAbsent = expectedAbsent
        self.size = size
        self.updatedAt = updatedAt
        self.hash = hash
        self.content = content
    }

    /// Whether the file is over the Gateway's write cap (reported size, else its content).
    public var isTooLarge: Bool {
        (self.size ?? self.content.map(AgentManagement.byteCount) ?? 0) > AgentManagement.maxFileBytes
    }
}

/// `agents.files.list`'s result.
public struct AgentFileList: Hashable, Sendable {
    public let agentId: String
    public let workspace: String
    public let files: [AgentFileEntry]

    public init(_ json: JSONValue, agentId: String) {
        self.agentId = json["agentId"]?.text ?? agentId
        self.workspace = json["workspace"]?.text ?? ""
        self.files = json["files"]?.array?.compactMap(AgentFileEntry.init) ?? []
    }
}

/// `agent.identity.get`'s result.
public struct AgentIdentity: Hashable, Sendable {
    public let agentId: String
    public let name: String?
    /// config, agent, workspace or default.
    public let nameSource: String?
    public let avatar: String?
    /// none, local, remote or data.
    public let avatarStatus: String?
    public let avatarReason: String?
    public let emoji: String?

    public init(_ json: JSONValue, agentId: String) {
        self.agentId = json["agentId"]?.text ?? agentId
        self.name = json["name"]?.text
        self.nameSource = json["nameSource"]?.text
        self.avatar = json["avatar"]?.text
        self.avatarStatus = json["avatarStatus"]?.text
        self.avatarReason = json["avatarReason"]?.text
        self.emoji = json["emoji"]?.text
    }
}

/// `agents.delete`'s result.
public struct AgentDeleteResult: Hashable, Sendable {
    public struct Failure: Hashable, Sendable {
        public let path: String
        public let reason: String
    }

    public let agentId: String
    public let removedBindings: Int
    /// Paths moved to the Trash (`method: "trash"`).
    public let trashedPaths: [String]
    public let failed: [Failure]
    /// The Gateway couldn't finish removing the agent's data.
    public let purgeFailed: Bool

    public init(_ json: JSONValue, agentId: String) {
        self.agentId = json["agentId"]?.text ?? agentId
        self.removedBindings = json["removedBindings"]?.int ?? 0
        self.trashedPaths = (json["removed"]?.array ?? []).compactMap { entry in
            entry["method"]?.text == "trash" ? entry["path"]?.text : nil
        }
        self.failed = (json["failed"]?.array ?? []).compactMap { entry in
            entry["path"]?.text.map { Failure(path: $0, reason: entry["reason"]?.text ?? "Unknown error") }
        }
        self.purgeFailed = json["purgeFailed"]?.bool ?? false
    }

    /// "Removed 2 bindings; moved 3 items to Trash."
    public var summary: String {
        var parts = ["Removed \(self.removedBindings) binding\(self.removedBindings == 1 ? "" : "s")"]
        if !self.trashedPaths.isEmpty {
            parts.append("moved \(self.trashedPaths.count) item\(self.trashedPaths.count == 1 ? "" : "s") to Trash")
        }
        return parts.joined(separator: "; ") + "."
    }
}

/// What duplicating an agent did.
public struct AgentDuplicateResult: Hashable, Sendable {
    public let agentId: String
    public let copiedFiles: [String]
    /// File name → why it couldn't be copied. The agent exists either way.
    public let failedFiles: [String: String]

    /// "Couldn't copy SOUL.md: …" lines, in name order.
    public var failureLines: [String] {
        self.failedFiles.keys.sorted().map { "Couldn't copy \($0): \(self.failedFiles[$0] ?? "")" }
    }
}

/// A save refused because the file changed on the Gateway since it was read.
public struct AgentFileConflict: Hashable, Sendable {
    public let name: String
    /// The unsaved text.
    public let yours: String
    /// What's on the Gateway now; nil when the file is missing there (or couldn't be read).
    public let theirs: String?
    /// The hash to overwrite with (`currentHash`, else from a fresh read).
    public let theirsHash: String?
    /// The file doesn't exist on the Gateway now.
    public let theirsMissing: Bool
}

// MARK: Errors

/// What an agent management failure means for the UI.
public enum AgentManagementError: Error, Equatable, Sendable {
    /// Needs `operator.admin` (Full Management).
    case needsAdmin
    /// The Gateway doesn't have the method.
    case unsupported
    /// `agent_file_conflict`: the file changed since it was read.
    case conflict(currentHash: String?)
    /// `agent "x" not found`.
    case notFound(String)
    /// Over the 2 MiB cap; checked before sending.
    case tooLarge(bytes: Int)
    /// Another `INVALID_REQUEST` (reserved or existing id, the only agent, unsupported file…), verbatim.
    case validation(String)
    case other(String)

    public static func classify(_ error: Error) -> AgentManagementError {
        if let error = error as? AgentManagementError { return error }
        guard case let GatewayError.rpc(code, message, details) = error else {
            return .other(error.localizedDescription)
        }
        let lower = message.lowercased()
        if details?["type"]?.text == AgentManagement.conflictErrorType || lower.contains("changed since it was read") {
            return .conflict(currentHash: details?["currentHash"]?.text?.lowercased())
        }
        if code == "MISSING_SCOPE" || details?["code"]?.text == "MISSING_SCOPE"
            || lower.contains("missing scope") || lower.contains("operator.admin")
        {
            return .needsAdmin
        }
        if code == "UNKNOWN_METHOD" || code == "METHOD_NOT_FOUND" || lower.contains("unknown method") { return .unsupported }
        if lower.hasPrefix("agent \""), lower.hasSuffix("not found") { return .notFound(message) }
        if code == "INVALID_REQUEST" { return .validation(message) }
        return .other(message)
    }

    public var message: String {
        switch self {
        case .needsAdmin: AgentManagement.needsAdminMessage
        case .unsupported: AgentManagement.unsupportedMessage
        case .conflict: "The file changed on the gateway since you opened it."
        case let .notFound(message): message
        case let .tooLarge(bytes): AgentManagement.tooLargeMessage(bytes: bytes)
        case let .validation(message), let .other(message): message
        }
    }
}

// MARK: Model

/// Agent management for one Gateway (`GatewayStore.agentManagement`). Stateless apart from
/// capability tracking: the agent list lives in `GatewayStore.agents`, refreshed after every
/// mutation through `onAgentsChanged`.
@MainActor
@Observable
public final class AgentManagementModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// Set when a call hit a scope error, although the connection claimed `operator.admin`.
    public private(set) var deniedAdmin = false
    /// Bumped per agent on every saved file, so file lists reload.
    public private(set) var filesRevision: [String: Int] = [:]
    /// Methods the Gateway answered with unknown-method.
    public private(set) var rejectedMethods: Set<String> = []

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let scopes: @MainActor () -> [String]
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored private let onAgentsChanged: @MainActor () async -> Void

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?,
         allowsWritesWithoutAdmin: Bool, onAgentsChanged: @escaping @MainActor () async -> Void)
    {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.onAgentsChanged = onAgentsChanged
    }

    /// For checks and previews. `methods` is the advertised method list (nil or empty when
    /// unknown), `scopes` the connection's scopes.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [GatewayConnection.adminScope] },
                allowsWritesWithoutAdmin: Bool = false,
                onAgentsChanged: @escaping @MainActor () async -> Void = {},
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.onAgentsChanged = onAgentsChanged
    }

    // MARK: Capability

    /// Whether the Gateway has `method`: advertised (or the list is unknown) and not rejected.
    public func supports(_ method: String) -> Bool {
        if self.rejectedMethods.contains(method) { return false }
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    /// Full Management (or the demo).
    public var hasAdmin: Bool {
        if self.allowsWritesWithoutAdmin { return true }
        return !self.deniedAdmin && self.scopes().contains(GatewayConnection.adminScope)
    }

    /// The Gateway can create, edit and delete agents.
    public var managementSupported: Bool {
        self.supports(AgentManagement.createMethod) && self.supports(AgentManagement.updateMethod)
            && self.supports(AgentManagement.deleteMethod)
    }

    public var filesSupported: Bool {
        self.supports(AgentManagement.filesListMethod) && self.supports(AgentManagement.filesGetMethod)
    }

    public var canManageAgents: Bool { self.hasAdmin && self.managementSupported }
    public var canWriteFiles: Bool { self.hasAdmin && self.filesSupported && self.supports(AgentManagement.filesSetMethod) }

    /// Why workspace files are read-only, or nil when they can be saved.
    public var filesReadOnlyReason: String? {
        if !self.filesSupported || !self.supports(AgentManagement.filesSetMethod) {
            return "This gateway can't save workspace files. Update OpenClaw to edit them here."
        }
        if !self.hasAdmin { return AgentManagement.needsAdminMessage }
        return nil
    }

    /// Why edits are off, or nil when they're allowed.
    public var readOnlyReason: String? {
        if !self.managementSupported { return AgentManagement.unsupportedMessage }
        if !self.hasAdmin { return AgentManagement.needsAdminMessage }
        return nil
    }

    // MARK: Agents

    /// Creates an agent; returns its id. Refreshes the agent list.
    @discardableResult
    public func create(_ draft: AgentDraft) async throws -> String {
        if let error = draft.validationError { throw AgentManagementError.validation(error) }
        let result = try await self.call(AgentManagement.createMethod, draft.createParams)
        let agentId = result["agentId"]?.text ?? draft.derivedId ?? draft.trimmedName
        await self.onAgentsChanged()
        return agentId
    }

    /// Sends only the changed fields. Returns false when nothing changed.
    @discardableResult
    public func update(agentId: String, original: AgentDraft, draft: AgentDraft) async throws -> Bool {
        guard let params = draft.updateParams(agentId: agentId, from: original) else { return false }
        if draft.trimmedName.isEmpty { throw AgentManagementError.validation("Enter a name.") }
        _ = try await self.call(AgentManagement.updateMethod, params)
        await self.onAgentsChanged()
        return true
    }

    /// Creates a copy from `draft` (see `AgentDraft.duplicate`), then optionally copies the source's
    /// existing workspace files into the new workspace. Bindings are never copied. File failures
    /// don't undo the new agent.
    public func duplicate(sourceId: String, draft: AgentDraft, copyFiles: Bool) async throws -> AgentDuplicateResult {
        let agentId = try await self.create(draft)
        guard copyFiles else { return AgentDuplicateResult(agentId: agentId, copiedFiles: [], failedFiles: [:]) }
        var copied: [String] = []
        var failed: [String: String] = [:]
        let sources: [AgentFileEntry]
        do {
            sources = try await self.listFiles(agentId: sourceId).files.filter { !$0.missing }
        } catch {
            return AgentDuplicateResult(agentId: agentId, copiedFiles: [], failedFiles: ["workspace files": AgentManagementError.classify(error).message])
        }
        for source in sources {
            do {
                let file = try await self.getFile(agentId: sourceId, name: source.name)
                guard !file.missing, let content = file.content else { continue }
                // The new workspace may already have seeded bootstrap files: replace exactly what's there.
                let target = try await self.getFile(agentId: agentId, name: source.name)
                if !target.missing, target.hash == file.hash {
                    copied.append(source.name)
                    continue
                }
                _ = try await self.setFile(agentId: agentId, name: source.name, content: content,
                                           expectedHash: target.missing ? nil : target.hash,
                                           expectedMissing: target.missing)
                copied.append(source.name)
            } catch {
                failed[source.name] = AgentManagementError.classify(error).message
            }
        }
        return AgentDuplicateResult(agentId: agentId, copiedFiles: copied, failedFiles: failed)
    }

    /// Always sends `deleteFiles` (the Gateway defaults it to true). Refreshes the agent list.
    public func delete(agentId: String, deleteFiles: Bool) async throws -> AgentDeleteResult {
        let result = try await self.call(AgentManagement.deleteMethod,
                                         ["agentId": .string(agentId), "deleteFiles": .bool(deleteFiles)])
        self.forget(agentId: agentId)
        await self.onAgentsChanged()
        return AgentDeleteResult(result, agentId: agentId)
    }

    public func identity(agentId: String) async throws -> AgentIdentity {
        AgentIdentity(try await self.call(AgentManagement.identityMethod, ["agentId": .string(agentId)]), agentId: agentId)
    }

    // MARK: Files

    public func listFiles(agentId: String) async throws -> AgentFileList {
        AgentFileList(try await self.call(AgentManagement.filesListMethod, ["agentId": .string(agentId)]), agentId: agentId)
    }

    public func getFile(agentId: String, name: String) async throws -> AgentFileEntry {
        try self.checkName(name)
        let result = try await self.call(AgentManagement.filesGetMethod, ["agentId": .string(agentId), "name": .string(name)])
        return AgentFileEntry(result["file"] ?? [:]) ?? AgentFileEntry(name: name, missing: true)
    }

    /// Writes a file with `expectedHash` (existing) or `expectedMissing` (new); never both.
    /// Passing neither sends an unconditional write (only an overwrite the user confirmed, when
    /// the Gateway's current hash is unknown). Checks the size cap first.
    public func setFile(agentId: String, name: String, content: String,
                        expectedHash: String?, expectedMissing: Bool) async throws -> AgentFileEntry
    {
        try self.checkName(name)
        let bytes = AgentManagement.byteCount(content)
        if bytes > AgentManagement.maxFileBytes { throw AgentManagementError.tooLarge(bytes: bytes) }
        var params: [String: JSONValue] = [
            "agentId": .string(agentId), "name": .string(name), "content": .string(content),
        ]
        if let expectedHash {
            params["expectedHash"] = .string(expectedHash.lowercased())
        } else if expectedMissing {
            params["expectedMissing"] = true
        }
        let result = try await self.call(AgentManagement.filesSetMethod, .object(params))
        self.filesRevision[agentId, default: 0] += 1
        return AgentFileEntry(result["file"] ?? [:])
            ?? AgentFileEntry(name: name, size: bytes, hash: AgentManagement.sha256Hex(content), content: content)
    }

    private func checkName(_ name: String) throws {
        guard AgentManagement.allowedFileNames.contains(name) else {
            throw AgentManagementError.validation("unsupported file \"\(name)\"")
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
            throw AgentManagementError.classify(error)
        }
    }

    // MARK: Drafts

    /// An agent page's unsaved edits, kept while moving between pages.
    public struct AgentEdit: Hashable, Sendable {
        public var original: AgentDraft
        public var draft: AgentDraft

        public init(original: AgentDraft, draft: AgentDraft) {
            self.original = original
            self.draft = draft
        }

        public var isDirty: Bool { self.draft.updateParams(agentId: "_", from: self.original) != nil }
    }

    /// What the last delete did, shown on the agent list after its page closes.
    public struct DeletionReport: Identifiable, Hashable, Sendable {
        public let id = UUID()
        public let agentName: String
        public let result: AgentDeleteResult

        public init(agentName: String, result: AgentDeleteResult) {
            self.agentName = agentName
            self.result = result
        }
    }

    public var deletionReport: DeletionReport?

    /// Unsaved agent edits by agent id.
    public private(set) var agentEdits: [String: AgentEdit] = [:]
    @ObservationIgnored private var editors: [String: AgentFileEditorModel] = [:]
    /// Open file editors, so drafts survive navigation and the close guard can find them.
    public private(set) var openEditors: [AgentFileEditorModel] = []

    /// The draft for an agent page: the unsaved one, else `original`.
    public func edit(agentId: String, original: AgentDraft) -> AgentEdit {
        if let edit = self.agentEdits[agentId], edit.isDirty { return edit }
        return AgentEdit(original: original, draft: original)
    }

    public func setDraft(_ draft: AgentDraft, agentId: String, original: AgentDraft) {
        let edit = AgentEdit(original: self.agentEdits[agentId]?.original ?? original, draft: draft)
        self.agentEdits[agentId] = edit.isDirty ? edit : nil
    }

    public func discardDraft(agentId: String) { self.agentEdits[agentId] = nil }

    /// Saves an agent page's draft. Returns false when it failed (the error is thrown).
    public func saveDraft(agentId: String) async throws {
        guard let edit = self.agentEdits[agentId] else { return }
        try await self.update(agentId: agentId, original: edit.original, draft: edit.draft)
        if self.agentEdits[agentId] == edit { self.agentEdits[agentId] = nil }
    }

    /// The editor for one file, shared by every view that shows it.
    public func editor(agentId: String, name: String) -> AgentFileEditorModel {
        let key = "\(agentId)/\(name)"
        if let editor = self.editors[key] { return editor }
        let editor = AgentFileEditorModel(agentId: agentId, name: name, management: self)
        self.editors[key] = editor
        self.openEditors.append(editor)
        return editor
    }

    /// Forgets a clean editor (its page closed).
    public func closeEditor(_ editor: AgentFileEditorModel) {
        guard !editor.isDirty else { return }
        self.editors["\(editor.agentId)/\(editor.name)"] = nil
        self.openEditors.removeAll { $0 === editor }
    }

    public var dirtyEditors: [AgentFileEditorModel] { self.openEditors.filter(\.isDirty) }
    public var dirtyAgentIds: [String] { self.agentEdits.filter(\.value.isDirty).keys.sorted() }
    public var hasUnsavedChanges: Bool { !self.dirtyEditors.isEmpty || !self.dirtyAgentIds.isEmpty }

    /// "SOUL.md", "Scout", or "3 documents": what the close dialog asks to save.
    public func unsavedTitle(agentNames: [String: String]) -> String {
        let names = self.dirtyEditors.map(\.name) + self.dirtyAgentIds.map { agentNames[$0] ?? $0 }
        return names.count == 1 ? names[0] : "\(names.count) documents"
    }

    /// Saves every draft. Returns false if any save failed or hit a conflict.
    public func saveAll() async -> Bool {
        var ok = true
        for editor in self.dirtyEditors where !(await editor.save()) { ok = false }
        for agentId in self.dirtyAgentIds {
            do { try await self.saveDraft(agentId: agentId) } catch { ok = false }
        }
        return ok
    }

    public func discardAll() {
        for editor in self.dirtyEditors { editor.revert() }
        self.agentEdits = [:]
        for editor in self.openEditors { self.closeEditor(editor) }
    }

    /// Drops drafts of an agent that no longer exists.
    func forget(agentId: String) {
        self.agentEdits[agentId] = nil
        for editor in self.openEditors where editor.agentId == agentId {
            self.editors["\(agentId)/\(editor.name)"] = nil
        }
        self.openEditors.removeAll { $0.agentId == agentId }
    }

    /// A reconnect may bring new scopes or a newer Gateway.
    func handleReconnect() {
        self.deniedAdmin = false
        self.rejectedMethods = []
    }
}

// MARK: File editor

/// One open workspace file: the loaded version, the draft, and save/conflict state.
@MainActor
@Observable
public final class AgentFileEditorModel {
    public let agentId: String
    public let name: String
    /// The last loaded or saved version.
    public private(set) var entry: AgentFileEntry?
    /// The editor's text.
    public var text = ""
    public private(set) var loadState = OperationState.idle
    public private(set) var saveState = OperationState.idle
    public private(set) var conflict: AgentFileConflict?
    /// The last save or load error that isn't a conflict.
    public private(set) var error: AgentManagementError?
    /// Changes on every successful save.
    public private(set) var lastSave: UUID?

    @ObservationIgnored private let management: AgentManagementModel
    @ObservationIgnored private var savedText = ""

    public init(agentId: String, name: String, management: AgentManagementModel) {
        self.agentId = agentId
        self.name = name
        self.management = management
    }

    public var hasLoaded: Bool { self.entry != nil }
    public var isDirty: Bool { self.hasLoaded && self.text != self.savedText }
    public var isSaving: Bool { self.saveState.isRunning }
    public var byteCount: Int { AgentManagement.byteCount(self.text) }
    public var exceedsLimit: Bool { self.byteCount > AgentManagement.maxFileBytes }
    /// The file doesn't exist yet: saving creates it.
    public var isNew: Bool { self.entry?.missing ?? false }
    /// The Gateway's copy is over the cap: shown read-only.
    public var loadedTooLarge: Bool { self.entry?.isTooLarge ?? false }
    public var canEdit: Bool { self.management.canWriteFiles && self.hasLoaded && !self.loadedTooLarge }
    public var canSave: Bool {
        self.canEdit && (self.isDirty || self.isNew) && !self.exceedsLimit && !self.isSaving && self.conflict == nil
    }

    /// Reads the file, discarding any draft.
    public func load() async {
        self.loadState = .running
        do {
            let entry = try await self.management.getFile(agentId: self.agentId, name: self.name)
            self.apply(entry)
            self.error = nil
            self.conflict = nil
            self.loadState = .idle
        } catch {
            let classified = AgentManagementError.classify(error)
            self.loadState = .failed(classified.message)
        }
    }

    public func loadIfNeeded() async {
        if !self.hasLoaded, !self.loadState.isRunning { await self.load() }
    }

    public func revert() {
        self.text = self.savedText
        self.error = nil
    }

    /// Saves with the loaded version's hash (or `expectedMissing` for a new file). A conflict
    /// fetches the Gateway's version into `conflict` and keeps the draft.
    @discardableResult
    public func save() async -> Bool {
        guard let entry, !self.isSaving else { return false }
        if self.exceedsLimit {
            self.error = .tooLarge(bytes: self.byteCount)
            return false
        }
        return await self.write(expectedHash: entry.missing ? nil : entry.hash, expectedMissing: entry.missing)
    }

    /// Drops the draft and shows the Gateway's version.
    public func resolveConflictKeepTheirs() async {
        self.conflict = nil
        await self.load()
    }

    /// Writes the draft over the Gateway's current version (the one in `conflict`).
    @discardableResult
    public func resolveConflictOverwrite() async -> Bool {
        guard let conflict else { return false }
        self.conflict = nil
        return await self.write(expectedHash: conflict.theirsMissing ? nil : conflict.theirsHash,
                                expectedMissing: conflict.theirsMissing)
    }

    private func write(expectedHash: String?, expectedMissing: Bool) async -> Bool {
        let content = self.text
        self.saveState = .running
        self.error = nil
        do {
            let saved = try await self.management.setFile(agentId: self.agentId, name: self.name, content: content,
                                                          expectedHash: expectedHash, expectedMissing: expectedMissing)
            // Keep typing done during the save as a draft on top of the saved version.
            let typed = self.text
            self.apply(AgentFileEntry(name: saved.name, path: saved.path, missing: false, expectedAbsent: saved.expectedAbsent,
                                      size: saved.size ?? AgentManagement.byteCount(content), updatedAt: saved.updatedAt,
                                      hash: saved.hash ?? AgentManagement.sha256Hex(content), content: content))
            self.text = typed
            self.saveState = .idle
            self.lastSave = UUID()
            return true
        } catch {
            let classified = AgentManagementError.classify(error)
            if case let .conflict(currentHash) = classified {
                self.conflict = await self.fetchConflict(yours: content, currentHash: currentHash)
                self.saveState = .idle
            } else {
                self.error = classified
                self.saveState = .failed(classified.message)
            }
            return false
        }
    }

    private func fetchConflict(yours: String, currentHash: String?) async -> AgentFileConflict {
        if let theirs = try? await self.management.getFile(agentId: self.agentId, name: self.name) {
            return AgentFileConflict(name: self.name, yours: yours, theirs: theirs.content,
                                     theirsHash: theirs.hash ?? currentHash, theirsMissing: theirs.missing)
        }
        return AgentFileConflict(name: self.name, yours: yours, theirs: nil, theirsHash: currentHash, theirsMissing: false)
    }

    private func apply(_ entry: AgentFileEntry) {
        self.entry = entry
        self.savedText = entry.content ?? ""
        self.text = self.savedText
    }
}
