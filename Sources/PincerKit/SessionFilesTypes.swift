import Foundation

/// A file a session touched (`sessions.files.list` → `files[]`). Upstream orders changed files first, then by path.
public struct SessionFileItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case modified, read }

    public let path: String
    public let name: String
    public let kind: Kind
    /// The file no longer exists on the Gateway ("Deleted").
    public let missing: Bool
    public let size: Int?
    public let updatedAtMs: Double?

    public var id: String { self.path }

    public init(path: String, name: String, kind: Kind, missing: Bool, size: Int? = nil, updatedAtMs: Double? = nil) {
        self.path = path
        self.name = name
        self.kind = kind
        self.missing = missing
        self.size = size
        self.updatedAtMs = updatedAtMs
    }
}

/// One entry of the project-files listing (`sessions.files.list` → `browser.entries[]`).
public struct SessionFileTreeEntry: Identifiable, Hashable, Sendable {
    /// `sessionKind`: whether the session changed, read or both touched the entry.
    public enum Relevance: String, Sendable { case modified, read, mixed }

    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let relevance: Relevance?
    public let size: Int?

    public var id: String { self.path }

    public init(path: String, name: String, isDirectory: Bool, relevance: Relevance? = nil, size: Int? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.relevance = relevance
        self.size = size
    }
}

/// A visible row of the flattened project-files tree.
public struct SessionFileTreeRow: Identifiable, Hashable, Sendable {
    public let entry: SessionFileTreeEntry
    public let depth: Int
    public let isExpanded: Bool
    /// A folder whose children are being fetched.
    public let isLoading: Bool

    public var id: String { self.entry.path }
}

/// An artifact the session produced (`artifacts.list` → `artifacts[]`).
public struct SessionArtifactItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let title: String
    public let mimeType: String?
    public let sizeBytes: Int?
}

public enum SessionFilesFilter: String, CaseIterable, Sendable {
    case all, changed, read, artifacts
}

/// What the Files tab shows, finished off-main. The main actor only assigns it.
public struct SessionFilesSnapshot: Equatable, Sendable {
    public struct Counts: Equatable, Sendable {
        public var changed = 0
        public var read = 0
        public var artifacts = 0
    }

    /// The workspace root on the Gateway host.
    public var root: String?
    public var gitCheckout: Bool?
    /// Groups hidden by the chip are empty. Search applies to all of them.
    public var changed: [SessionFileItem] = []
    public var read: [SessionFileItem] = []
    public var artifacts: [SessionArtifactItem] = []
    /// The project tree, flattened for the current expansion state. Only filled for the `All` chip.
    public var tree: [SessionFileTreeRow] = []
    /// Chip counts, before the chip but after search.
    public var counts = Counts()
    /// The Gateway cut the folder listing short (250 entries; 500 for a search).
    public var treeTruncated = false
    /// How many entries the listing at the root held; for "Showing the first N entries".
    public var treeEntryCount = 0
    /// `artifacts.list` left out oversized artifacts.
    public var artifactsOmittedOversized = false

    public var isEmpty: Bool { self.changed.isEmpty && self.read.isEmpty && self.artifacts.isEmpty && self.tree.isEmpty }

    public init() {}
}

/// A mapped `sessions.files.*` failure. Messages never carry paths from the Gateway beyond what the caller shows.
public enum SessionFilesError: Error, Equatable, Sendable {
    /// `session_file_conflict`: the file changed since it was read. `currentHash` is the Gateway's current hash.
    case conflict(currentHash: String?)
    /// `session_file_too_large`: over the 256 KiB preview/edit cap.
    case tooLarge(size: Int?)
    /// `session_file_not_found`.
    case notFound
    /// `session_file_unsafe`: the content can't be written safely (NUL or invalid UTF-8).
    case unsafe
    /// `device_folder_files_unavailable`.
    case deviceFolder
    case missingScope
    case unsupported
    case notConnected
    case failed(String)

    public var message: String {
        switch self {
        case .conflict: L("This file changed since you opened it.")
        case .tooLarge: L("This file is too large to preview or edit.")
        case .notFound: L("This file no longer exists on the gateway.")
        case .unsafe: L("Pincer can't save this content safely.")
        case .deviceFolder: L("Files aren't available for folders on paired devices.")
        case .missingScope: L("Editing files needs Full Management.")
        case .unsupported: L("This gateway doesn't support session files.")
        case .notConnected: L("Not connected to the Gateway.")
        case let .failed(text): text
        }
    }

    /// Reads `details.type` as upstream's `sessionFilesError` shapes it.
    static func map(_ error: Error) -> SessionFilesError {
        if case GatewayError.notConnected = error { return .notConnected }
        if case let GatewayError.rpc(_, _, details) = error, let type = details?["type"]?.string {
            switch type {
            case "session_file_conflict": return .conflict(currentHash: details?["currentHash"]?.string)
            case "session_file_too_large": return .tooLarge(size: details?["size"]?.int)
            case "session_file_not_found": return .notFound
            case "session_file_unsafe": return .unsafe
            case "device_folder_files_unavailable": return .deviceFolder
            default: break
            }
        }
        switch GatewayError.classify(error) {
        case .missingScope: return .missingScope
        case .unsupported: return .unsupported
        case let .message(text): return .failed(BrowserPanelModel.sanitized(text))
        }
    }
}

/// Wire parsing, kept pure and off the main actor.
enum SessionFilesParser {
    static let maxFiles = 5_000
    static let maxEntries = 1_000
    static let maxArtifacts = 500

    struct List: Sendable {
        var root: String?
        var gitCheckout: Bool?
        var files: [SessionFileItem] = []
        var browserPath: String?
        var entries: [SessionFileTreeEntry] = []
        var truncated = false
    }

    static func list(_ value: JSONValue) -> List {
        var result = List()
        result.root = value["root"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        result.gitCheckout = value["gitCheckout"]?.bool
        result.files = (value["files"]?.array ?? []).prefix(self.maxFiles).compactMap(self.file)
        if let browser = value["browser"] {
            result.browserPath = browser["path"]?.string ?? ""
            result.entries = (browser["entries"]?.array ?? []).prefix(self.maxEntries).compactMap(self.entry)
            result.truncated = browser["truncated"]?.bool ?? false
        }
        return result
    }

    static func file(_ row: JSONValue) -> SessionFileItem? {
        guard let path = row["path"]?.string, !path.isEmpty,
              let kind = row["kind"]?.string.flatMap(SessionFileItem.Kind.init(rawValue:)) else { return nil }
        let name = row["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent
        return SessionFileItem(path: path, name: name, kind: kind, missing: row["missing"]?.bool ?? false,
                               size: row["size"]?.int, updatedAtMs: row["updatedAtMs"]?.double)
    }

    static func entry(_ row: JSONValue) -> SessionFileTreeEntry? {
        guard let path = row["path"]?.string, let name = row["name"]?.string, !name.isEmpty,
              let kind = row["kind"]?.string, kind == "file" || kind == "directory" else { return nil }
        return SessionFileTreeEntry(path: path, name: name, isDirectory: kind == "directory",
                                    relevance: row["sessionKind"]?.string.flatMap(SessionFileTreeEntry.Relevance.init(rawValue:)),
                                    size: row["size"]?.int)
    }

    static func artifacts(_ value: JSONValue) -> (items: [SessionArtifactItem], omittedOversized: Bool) {
        let items: [SessionArtifactItem] = (value["artifacts"]?.array ?? []).prefix(self.maxArtifacts).compactMap { row in
            guard let id = row["id"]?.string, !id.isEmpty, let type = row["type"]?.string,
                  let title = row["title"]?.string else { return nil }
            return SessionArtifactItem(id: id, type: type, title: title, mimeType: row["mimeType"]?.string,
                                       sizeBytes: row["sizeBytes"]?.int)
        }
        return (items, value["omittedOversized"]?.bool ?? false)
    }

    /// Flattens the tree for the expanded folders, depth first. A folder with no fetched children shows none.
    static func flatten(root: [SessionFileTreeEntry], children: [String: [SessionFileTreeEntry]], expanded: Set<String>,
                        loading: Set<String>, search: String) -> [SessionFileTreeRow]
    {
        var rows: [SessionFileTreeRow] = []
        var visited = Set<String>()
        func visit(_ entries: [SessionFileTreeEntry], depth: Int) {
            for entry in entries {
                let isOpen = entry.isDirectory && expanded.contains(entry.path) && search.isEmpty
                rows.append(SessionFileTreeRow(entry: entry, depth: depth, isExpanded: isOpen,
                                               isLoading: loading.contains(entry.path)))
                if isOpen, visited.insert(entry.path).inserted, let kids = children[entry.path] {
                    visit(kids, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        return rows
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }
}
