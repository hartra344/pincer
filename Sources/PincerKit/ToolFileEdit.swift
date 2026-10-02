import Foundation
import Synchronization

/// One line of a rendered diff, without its `+`/`-`/space sign.
public struct DiffLine: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case context, addition, deletion
    }

    public let kind: Kind
    public let text: String
    /// Line number in the file, when the source knew it: the new file's for additions and
    /// context, the old file's for deletions.
    public let lineNumber: Int?

    public init(_ kind: Kind, _ text: String, lineNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.lineNumber = lineNumber
    }

    public var sign: String {
        switch self.kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        }
    }

    /// The line as it appears in a unified diff.
    public var unified: String { self.sign + self.text }
}

/// A run of diff lines. Hunks of one file are shown with a `⋯` separator between them.
public struct DiffHunk: Hashable, Sendable {
    public let lines: [DiffLine]
    /// First old and new line numbers, from a `@@ -a,b +c,d @@` header or numbered lines.
    public let oldStart: Int?
    public let newStart: Int?

    public init(lines: [DiffLine], oldStart: Int? = nil, newStart: Int? = nil) {
        self.lines = lines
        self.oldStart = oldStart
        self.newStart = newStart
    }

    public var additions: Int { self.lines.count { $0.kind == .addition } }
    public var deletions: Int { self.lines.count { $0.kind == .deletion } }

    /// `@@ -a,b +c,d @@` when the start lines are known, else a bare `@@`.
    public var header: String {
        guard let oldStart, let newStart else { return "@@" }
        let oldCount = self.lines.count { $0.kind != .addition }
        let newCount = self.lines.count { $0.kind != .deletion }
        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

/// The change to one file.
public struct FileDiff: Hashable, Sendable {
    public enum Operation: String, Hashable, Sendable {
        case add, update, delete, move
    }

    /// Where the file ends up (the destination of a move). Nil when the call named no path.
    public let path: String?
    /// Where a moved file came from; nil unless `operation == .move`.
    public let sourcePath: String?
    public let operation: Operation
    /// Only the hunks kept under the render caps.
    public let hunks: [DiffHunk]
    /// Counted over the whole change, including lines past the render cap.
    public let additions: Int
    public let deletions: Int

    public init(path: String?, sourcePath: String? = nil, operation: Operation, hunks: [DiffHunk],
                additions: Int? = nil, deletions: Int? = nil)
    {
        self.path = path
        self.sourcePath = sourcePath
        self.operation = operation
        self.hunks = hunks
        self.additions = additions ?? hunks.reduce(0) { $0 + $1.additions }
        self.deletions = deletions ?? hunks.reduce(0) { $0 + $1.deletions }
    }

    /// "Update a.swift", "Add a.swift", "Delete a.swift", "Move a.swift → b.swift".
    public var label: String {
        let path = self.path ?? "file"
        switch self.operation {
        case .add: return "Add \(path)"
        case .update: return "Update \(path)"
        case .delete: return "Delete \(path)"
        case .move: return "Move \(self.sourcePath ?? "file") → \(path)"
        }
    }

    /// `--- a/…` / `+++ b/…` headers and hunks.
    public var unifiedText: String {
        let old = self.operation == .add ? "/dev/null" : "a/\(self.sourcePath ?? self.path ?? "file")"
        let new = self.operation == .delete ? "/dev/null" : "b/\(self.path ?? "file")"
        var out = ["--- \(old)", "+++ \(new)"]
        for hunk in self.hunks {
            out.append(hunk.header)
            out += hunk.lines.map(\.unified)
        }
        return out.joined(separator: "\n")
    }
}

/// A file-changing tool call (`write`, `edit`, `apply_patch` and their aliases) read as a diff,
/// so its card can show the change rather than raw JSON arguments. Pure and deterministic:
/// build it once per call and cache it, never in a view's `body`.
public struct ToolFileEdit: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Whole-file content (`write`, `str_replace_editor` `create`).
        case write
        /// Old/new text pairs (`edit`, `multi_edit`, `str_replace_editor` `str_replace`).
        case edit
        /// Text inserted at a line (`str_replace_editor` `insert`, notebook cells).
        case insert
        /// A patch envelope or unified diff (`apply_patch`).
        case patch
    }

    /// One visual row of the diff, in display order.
    public enum Row: Hashable, Sendable {
        /// A file's label, for multi-file patches or a move/delete with no lines to show.
        case file(FileDiff)
        /// `⋯` between hunks and edit pairs.
        case separator
        case line(DiffLine)
        /// "Diff truncated — N more lines"; N is nil when the source itself was clipped.
        case truncated(omitted: Int?)
    }

    public enum Limits {
        /// Lines per side fed to the line diff.
        public static let maxInputLines = 600
        /// UTF-16 characters of old+new text (or patch text) read per call.
        public static let maxInputCharacters = 120_000
        /// `edits[]` pairs read per call.
        public static let maxEditPairs = 8
        /// Diff lines kept across all files and hunks.
        public static let maxRenderedLines = 400
        /// Lines of a `write` shown.
        public static let maxWritePreviewLines = 80
        /// Unchanged lines kept around a change when a long diff is shortened.
        public static let contextLines = 3
        /// Characters of one line drawn; the rest is cut with `…` (Copy keeps whole lines).
        public static let maxLineCharacters = 1_000
        /// Rows past which the card starts collapsed.
        public static let collapseThreshold = 20
        /// Rows a collapsed card shows.
        public static let collapsedRows = 12
    }

    public let kind: Kind
    public let files: [FileDiff]
    /// Lines added/removed across all files. See `isStatExact`.
    public let additions: Int
    public let deletions: Int
    /// How far `additions` / `deletions` can be trusted: a cap or the source can hide part of
    /// the change (the count is a lower bound), and an overwrite doesn't say what it removed.
    public let additionsBound: StatBound
    public let deletionsBound: StatBound
    /// Both counts are the whole change.
    public var isStatExact: Bool { self.additionsBound == .exact && self.deletionsBound == .exact }
    /// Some of the change isn't shown.
    public let isTruncated: Bool
    /// Diff lines not shown, when known.
    public let omittedLines: Int?
    /// What Copy puts on the pasteboard: the raw content for a write, else the unified diff.
    public let copyText: String

    public enum StatBound: Hashable, Sendable {
        case exact
        /// At least this many; shown with a trailing "+".
        case atLeast
        /// Not known at all; not shown.
        case unknown
    }

    public init(kind: Kind, files: [FileDiff], additionsBound: StatBound = .exact, deletionsBound: StatBound = .exact,
                isTruncated: Bool = false, omittedLines: Int? = nil, copyText: String? = nil)
    {
        self.kind = kind
        self.files = files
        self.additions = files.reduce(0) { $0 + $1.additions }
        self.deletions = files.reduce(0) { $0 + $1.deletions }
        self.additionsBound = additionsBound
        self.deletionsBound = deletionsBound
        self.isTruncated = isTruncated || (omittedLines ?? 0) > 0
        self.omittedLines = omittedLines
        if let copyText {
            self.copyText = copyText
        } else {
            // Review text, not a patch to apply: say where it was cut.
            let unified = files.map(\.unifiedText).joined(separator: "\n")
            self.copyText = self.isTruncated
                ? unified + (unified.isEmpty ? "" : "\n") + Self.text(for: .truncated(omitted: omittedLines)) : unified
        }
    }

    public init(kind: Kind, files: [FileDiff], isStatExact: Bool, isTruncated: Bool = false,
                omittedLines: Int? = nil, copyText: String? = nil)
    {
        let bound: StatBound = isStatExact ? .exact : .atLeast
        self.init(kind: kind, files: files, additionsBound: bound, deletionsBound: bound, isTruncated: isTruncated,
                  omittedLines: omittedLines, copyText: copyText)
    }

    // MARK: Presentation

    public var unifiedText: String { self.files.map(\.unifiedText).joined(separator: "\n") }

    /// The one file's path, or nil for a multi-file patch.
    public var primaryPath: String? { self.files.count == 1 ? self.files[0].path : nil }

    /// "Foo.swift", "Old.swift → New.swift", or "3 files".
    public var title: String {
        guard self.files.count == 1 else { return "\(self.files.count) files" }
        let file = self.files[0]
        let name = file.path.map(Self.fileName) ?? "file"
        if file.operation == .move, let source = file.sourcePath {
            let from = Self.fileName(source)
            return from == name ? "\(source) → \(file.path ?? name)" : "\(from) → \(name)"
        }
        return name
    }

    /// The single file's directory, shown dimmer than its name. Nil for moves and multi-file patches.
    public var directory: String? {
        guard self.files.count == 1, self.files[0].operation != .move, let path = self.files[0].path else { return nil }
        let dir = Self.directory(path)
        return dir.isEmpty ? nil : dir
    }

    /// Every path involved, for a tooltip.
    public var fullPaths: String {
        self.files.map { file in
            if file.operation == .move, let source = file.sourcePath { return "\(source) → \(file.path ?? "")" }
            return file.path ?? "file"
        }.joined(separator: "\n")
    }

    /// "New file", "Edited", "Deleted", "Moved", "Inserted", "Written" or "Patch".
    public var statusLabel: String { self.statusLabel(isRunning: false) }

    /// While a write runs nothing says yet whether it creates the file: "Writing".
    public func statusLabel(isRunning: Bool) -> String {
        switch self.kind {
        case .write where isRunning: return "Writing"
        case .write: return self.files.first?.operation == .add ? "New file" : "Written"
        case .insert: return "Inserted"
        case .edit: return "Edited"
        case .patch:
            guard self.files.count == 1 else { return "Patch" }
            switch self.files[0].operation {
            case .add: return "New file"
            case .delete: return "Deleted"
            case .move: return "Moved"
            case .update: return "Edited"
            }
        }
    }

    /// "+3", "+3+" (at least 3), or nil when there's nothing or nothing known to show.
    public var additionsLabel: String? { Self.countLabel("+", self.additions, self.additionsBound) }
    /// "−1", "−12+" (at least 12), or nil.
    /// Header-only deletes have no removed-line count. A single-file patch already says "Deleted"
    /// in its badge, while a multi-file patch needs this label to identify deleted files.
    public var deletionsLabel: String? {
        if let label = Self.countLabel("−", self.deletions, self.deletionsBound) { return label }
        let deleted = self.headerOnlyDeletedFileCount
        guard deleted > 0 else { return nil }
        if self.kind == .patch, self.files.count == 1, self.files[0].operation == .delete { return nil }
        return deleted == 1 ? L("1 file deleted") : L("\(deleted) files deleted")
    }

    private var headerOnlyDeletedFileCount: Int {
        self.deletions == 0 ? self.files.count { $0.operation == .delete } : 0
    }

    private static func countLabel(_ sign: String, _ count: Int, _ bound: StatBound) -> String? {
        guard count > 0, bound != .unknown else { return nil }
        return sign + String(count) + (bound == .atLeast ? "+" : "")
    }

    /// "Edited foo.swift, 3 added, 1 removed", for VoiceOver.
    public var accessibilitySummary: String { self.accessibilitySummary(isRunning: false) }

    /// "Edited foo.swift, 3 added, at least 12 removed"; a running write is "Writing foo.swift".
    public func accessibilitySummary(isRunning: Bool) -> String {
        let title = self.title.replacingOccurrences(
            of: "→", with: L("to", comment: "File edit summary: the arrow in a move, as in “a.swift to b.swift”"))
        let action: String = switch self.files.count == 1 ? self.files[0].operation : .update {
        case _ where isRunning && self.kind == .write: L("Writing \(title)")
        case .add: L("Created \(title)")
        case .delete: L("Deleted \(title)")
        case .move: L("Moved \(title)")
        case .update: self.kind == .write ? L("Wrote \(title)") : L("Edited \(title)")
        }
        var counts: [String] = []
        if self.additions > 0, self.additionsBound != .unknown {
            counts.append(self.additionsBound == .atLeast ? L("at least \(self.additions) added") : L("\(self.additions) added"))
        }
        if self.deletions > 0, self.deletionsBound != .unknown {
            counts.append(self.deletionsBound == .atLeast ? L("at least \(self.deletions) removed") : L("\(self.deletions) removed"))
        }
        if counts.isEmpty, self.headerOnlyDeletedFileCount > 0, let label = self.deletionsLabel { counts.append(label) }
        return ([action] + counts).joined(separator: ", ")
    }

    /// Every row, in order.
    public var rows: [Row] {
        var rows: [Row] = []
        let showsFileRows = self.files.count > 1
        for file in self.files {
            if showsFileRows || file.hunks.isEmpty {
                if !rows.isEmpty, rows.last != .separator { rows.append(.separator) }
                rows.append(.file(file))
            }
            for (index, hunk) in file.hunks.enumerated() {
                if index > 0 { rows.append(.separator) }
                rows += hunk.lines.map(Row.line)
            }
        }
        if self.isTruncated { rows.append(.truncated(omitted: self.omittedLines)) }
        return rows
    }

    /// A row as the card draws it. Find counts matches in these strings, so they must match the view.
    public static func text(for row: Row) -> String {
        switch row {
        case let .file(file): file.label
        case .separator: "⋯"
        case let .line(line):
            line.text.count > Limits.maxLineCharacters
                ? line.sign + line.text.prefix(Limits.maxLineCharacters) + "…" : line.unified
        case let .truncated(omitted?) where omitted > 0: "Diff truncated — \(omitted) more line\(omitted == 1 ? "" : "s")"
        case .truncated: "Diff truncated"
        }
    }

    /// Every row's text, one per line, as the expanded card shows it.
    public var displayText: String { self.rows.map(Self.text(for:)).joined(separator: "\n") }

    /// Whether the card should start collapsed.
    public var isLarge: Bool { self.rows.count > Limits.collapseThreshold }

    /// The rows to show and how many are hidden: all of them when expanded or small, otherwise the
    /// first `Limits.collapsedRows`.
    public func rows(collapsed: Bool) -> (rows: [Row], hidden: Int) {
        let all = self.rows
        guard collapsed, all.count > Limits.collapseThreshold else { return (all, 0) }
        return (Array(all.prefix(Limits.collapsedRows)), all.count - Limits.collapsedRows)
    }

    static func fileName(_ path: String) -> String {
        let trimmed = Self.normalized(path)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func directory(_ path: String) -> String {
        let trimmed = Self.normalized(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }

    private static func normalized(_ path: String) -> String {
        var path = path.replacingOccurrences(of: "\\", with: "/")
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

// MARK: Cache

extension ToolFileEdit {
    private struct CacheKey: Hashable {
        let name: String
        let arguments: String?
        let details: JSONValue?
        let isError: Bool
    }

    private static let cache = Mutex<[CacheKey: ToolFileEdit?]>([:])

    /// `parse`, remembered per call, so layouts and search don't diff the same call twice.
    public static func cached(toolName: String, arguments: String?, details: JSONValue?, isError: Bool) -> ToolFileEdit? {
        guard Self.handles(toolName: toolName) else { return nil }
        let key = CacheKey(name: toolName, arguments: arguments, details: details, isError: isError)
        if let hit = Self.cache.withLock({ $0[key] }) { return hit }
        let edit = Self.parse(toolName: toolName, arguments: arguments, details: details, isError: isError)
        Self.cache.withLock { cache in
            if cache.count > 500 { cache.removeAll(keepingCapacity: true) }
            cache[key] = .some(edit)
        }
        return edit
    }
}

extension ToolActivity {
    /// This call read as a file diff, or nil to show its raw arguments. Cached; cheap to call again.
    public var fileEdit: ToolFileEdit? {
        ToolFileEdit.cached(toolName: self.name, arguments: self.arguments, details: self.details, isError: self.isError)
    }
}

// MARK: Parsing

extension ToolFileEdit {
    static let editToolNames: Set<String> = ["edit", "edit_file", "multiedit", "multi_edit"]
    static let notebookToolNames: Set<String> = ["notebookedit", "notebook_edit"]
    static let textEditorToolNames: Set<String> = ["str_replace_editor", "str_replace_based_edit_tool"]
    static let writeToolNames: Set<String> = ["write", "write_file", "create_file"]
    static let patchToolNames: Set<String> = ["apply_patch", "applypatch", "patch"]

    static let pathKeys = ["path", "file_path", "filePath", "filepath", "notebook_path"]
    static let oldKeys = ["oldText", "old_string", "oldString", "old_str"]
    static let newKeys = ["newText", "new_string", "newString", "new_str"]

    /// Whether `name` is a file-changing tool this type can read.
    public static func handles(toolName name: String) -> Bool {
        let key = Self.key(name)
        return Self.editToolNames.contains(key) || Self.notebookToolNames.contains(key)
            || Self.textEditorToolNames.contains(key) || Self.writeToolNames.contains(key) || Self.patchToolNames.contains(key)
    }

    /// Reads a file-changing tool call. Nil when the tool isn't one, the arguments don't parse (still
    /// streaming, unknown shape), there's nothing to show, or the call failed without an applied
    /// diff: the card then shows the raw arguments.
    ///
    /// - Parameters:
    ///   - arguments: the call's arguments as JSON text.
    ///   - details: the result's `details`; an applied `details.diff` wins over the arguments.
    ///   - isError: the result reported an error.
    public static func parse(toolName: String, arguments: String?, details: JSONValue? = nil,
                             isError: Bool = false) -> ToolFileEdit?
    {
        let name = Self.key(toolName)
        guard Self.handles(toolName: name) else { return nil }
        let args = arguments.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONValue.decode($0) }?.object
        let path = args.flatMap { Self.string($0, Self.pathKeys) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filePath = path?.isEmpty == false ? path : nil
        if let diff = details?["diff"]?.string {
            // `details.diff` has no file headers. A multi-file patch keeps its per-file sections from
            // the input; a one-file patch takes its path from the envelope.
            let patch = Self.patchToolNames.contains(name) ? args.flatMap(Self.patch) : nil
            if let patch, patch.files.count > 1 { return patch }
            if let parsed = Self.detailsDiff(diff, path: filePath ?? patch?.files.first?.path, toolName: name,
                                              created: details?["created"]?.bool == true) {
                return parsed
            }
        }
        guard !isError, let args else { return nil }
        if Self.textEditorToolNames.contains(name) {
            switch Self.string(args, ["command"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "create":
                return Self.write(args, keys: ["file_text", "content"], path: filePath, details: details, createsFile: true)
            case "insert": return Self.insertion(Self.string(args, ["insert_text", "new_str"]), path: filePath,
                                                 at: args["insert_line"]?.int.map { $0 + 1 })
            case "view", "undo_edit": return nil
            default: return Self.edit(args, path: filePath)
            }
        }
        if Self.editToolNames.contains(name) { return Self.edit(args, path: filePath) }
        if Self.notebookToolNames.contains(name) {
            if let edit = Self.edit(args, path: filePath) { return edit }
            guard Self.string(args, ["edit_mode"])?.lowercased() != "delete" else { return nil }
            return Self.insertion(Self.string(args, ["new_source"]), path: filePath, at: nil, exact: false)
        }
        if Self.writeToolNames.contains(name) {
            return Self.write(args, keys: ["content", "text", "file_text"], path: filePath, details: details,
                              createsFile: name == "create_file")
        }
        return Self.patch(args)
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// First value under `keys` that reads as text: a string, or text blocks (`[{type: text, text}]`).
    static func string(_ record: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            guard let value = record[key] else { continue }
            if let text = Self.text(value) { return text }
        }
        return nil
    }

    private static func text(_ value: JSONValue) -> String? {
        switch value {
        case let .string(text): return text
        case let .array(items):
            let parts = items.compactMap { $0["text"]?.string ?? $0.string }
            return parts.count == items.count && !parts.isEmpty ? parts.joined() : nil
        case let .object(object): return object["text"]?.string
        default: return nil
        }
    }

    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: details.diff

    /// The Gateway's applied diff: numbered lines (`+ 12 text`, `- 3 text`, `  4 text`) with `...`
    /// between hunks and `...(truncated)...` where it was cut.
    static func detailsDiff(_ diff: String, path: String?, toolName: String, created: Bool = false) -> ToolFileEdit? {
        var hunks: [DiffHunk] = []
        var current: [DiffLine] = []
        var clipped = false
        var stored = 0
        var omitted = 0
        func closeHunk() {
            guard !current.isEmpty else { return }
            let oldStart = current.first { $0.kind != .addition }?.lineNumber
            let newStart = current.first { $0.kind != .deletion }?.lineNumber
            hunks.append(DiffHunk(lines: current, oldStart: oldStart, newStart: newStart))
            current = []
        }
        var additions = 0, deletions = 0
        for raw in Self.splitLines(diff) where !raw.isEmpty {
            let marker = raw.trimmingCharacters(in: .whitespaces)
            if marker == "..." || marker == "…" { closeHunk(); continue }
            if marker == "...(truncated)..." { clipped = true; closeHunk(); continue }
            guard let line = Self.numberedLine(raw) else { return nil }
            if line.kind == .addition { additions += 1 }
            if line.kind == .deletion { deletions += 1 }
            if stored < Limits.maxRenderedLines {
                current.append(line)
                stored += 1
            } else {
                omitted += 1
            }
        }
        closeHunk()
        guard additions + deletions > 0 else { return nil }
        let kind: Kind = Self.writeToolNames.contains(toolName) ? .write
            : Self.patchToolNames.contains(toolName) ? .patch : .edit
        // A write receipt with `created: true` made the file: nothing was removed.
        let isNew = created && kind == .write && deletions == 0
        let file = FileDiff(path: path, operation: isNew ? .add : .update, hunks: hunks, additions: additions,
                            deletions: deletions)
        return ToolFileEdit(kind: kind, files: [file], isStatExact: !clipped, isTruncated: clipped,
                            omittedLines: clipped ? nil : omitted)
    }

    private static func numberedLine(_ raw: String) -> DiffLine? {
        guard let sign = raw.first, sign == "+" || sign == "-" || sign == " " else { return nil }
        var rest = raw.dropFirst().drop { $0 == " " || $0 == "\t" }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        if rest.first == " " { rest = rest.dropFirst() }
        let kind: DiffLine.Kind = sign == "+" ? .addition : sign == "-" ? .deletion : .context
        return DiffLine(kind, String(rest), lineNumber: number)
    }

    // MARK: write / insert

    private static func write(_ args: [String: JSONValue], keys: [String], path: String?, details: JSONValue?,
                              createsFile: Bool = false) -> ToolFileEdit? {
        // The Gateway says nothing changed: there's no diff to show.
        guard details?["changed"]?.bool != false, let content = Self.string(args, keys) else { return nil }
        let all = Self.splitLines(content)
        guard !all.isEmpty else { return nil }
        var shown: [DiffLine] = []
        var budget = Limits.maxInputCharacters
        for (index, text) in all.prefix(Limits.maxWritePreviewLines).enumerated() {
            guard text.utf16.count <= budget else { break }
            budget -= text.utf16.count
            shown.append(DiffLine(.addition, text, lineNumber: index + 1))
        }
        // A plain write is new only when the Gateway says `created: true`; without that, an overwrite
        // can't be ruled out. Tools that only ever create (`create_file`, editor `create`) are new.
        let isNew = details?["created"]?.bool ?? createsFile
        let file = FileDiff(path: path, operation: isNew ? .add : .update,
                            hunks: [DiffHunk(lines: shown, oldStart: 0, newStart: 1)], additions: all.count, deletions: 0)
        // An overwrite's additions are the new content; what it replaced isn't known.
        return ToolFileEdit(kind: .write, files: [file], deletionsBound: isNew ? .exact : .unknown,
                            omittedLines: all.count - shown.count, copyText: content)
    }

    private static func insertion(_ text: String?, path: String?, at line: Int?, exact: Bool = true) -> ToolFileEdit? {
        guard let text else { return nil }
        let all = Self.splitLines(text)
        guard !all.isEmpty else { return nil }
        let kept = Array(all.prefix(Limits.maxRenderedLines))
        let lines = kept.enumerated().map { offset, text in DiffLine(.addition, text, lineNumber: line.map { $0 + offset }) }
        let file = FileDiff(path: path, operation: .update, hunks: [DiffHunk(lines: lines)], additions: all.count, deletions: 0)
        return ToolFileEdit(kind: .insert, files: [file], deletionsBound: exact ? .exact : .unknown,
                            omittedLines: all.count - kept.count)
    }

    // MARK: edit

    private static func edit(_ args: [String: JSONValue], path: String?) -> ToolFileEdit? {
        var pairs: [(old: String, new: String)] = []
        var clipped = false
        var characters = 0
        func add(_ record: [String: JSONValue]) -> Bool {
            guard let old = Self.string(record, Self.oldKeys), let new = Self.string(record, Self.newKeys) else { return true }
            let size = old.utf16.count + new.utf16.count
            guard characters + size <= Limits.maxInputCharacters else { return false }
            characters += size
            pairs.append((old, new))
            return true
        }
        if let edits = args["edits"]?.array {
            for (index, edit) in edits.enumerated() {
                guard index < Limits.maxEditPairs else { clipped = true; break }
                guard let record = edit.object else { continue }
                if !add(record) { clipped = true; break }
            }
        } else if !add(args) {
            clipped = true
        }
        guard !pairs.isEmpty else {
            // Too big to diff at all: still an edit, shown as "Diff truncated".
            return clipped ? ToolFileEdit(kind: .edit, files: [FileDiff(path: path, operation: .update, hunks: [])],
                                          isStatExact: false, isTruncated: true) : nil
        }
        var hunks: [DiffHunk] = []
        var exact = !clipped
        for pair in pairs {
            let result = DiffBuilder.diff(old: pair.old, new: pair.new)
            if result.isTruncated { exact = false }
            hunks += result.hunks
        }
        let capped = DiffBuilder.cap(hunks, budget: Limits.maxRenderedLines)
        guard capped.hunks.contains(where: { $0.additions + $0.deletions > 0 }) else { return nil }
        let file = FileDiff(path: path, operation: .update, hunks: capped.hunks,
                            additions: hunks.reduce(0) { $0 + $1.additions }, deletions: hunks.reduce(0) { $0 + $1.deletions })
        return ToolFileEdit(kind: .edit, files: [file], isStatExact: exact, isTruncated: !exact,
                            omittedLines: exact ? capped.omitted : nil)
    }

    // MARK: patch

    private struct PatchSection {
        var operation: FileDiff.Operation
        var sourcePath: String
        var path: String
        var hunks: [DiffHunk] = []
        var lines: [DiffLine] = []
        var oldStart: Int?
        var newStart: Int?
        var oldLine: Int?
        var newLine: Int?
        var additions = 0
        var deletions = 0

        mutating func closeHunk() {
            if !self.lines.isEmpty {
                self.hunks.append(DiffHunk(lines: self.lines, oldStart: self.oldStart, newStart: self.newStart))
            }
            self.lines = []
        }

        mutating func startHunk(old: Int?, new: Int?) {
            self.closeHunk()
            (self.oldStart, self.newStart, self.oldLine, self.newLine) = (old, new, old, new)
        }

        var file: FileDiff {
            var section = self
            section.closeHunk()
            let moved = section.operation == .update && section.path != section.sourcePath
            return FileDiff(path: section.path, sourcePath: moved ? section.sourcePath : nil,
                            operation: moved ? .move : section.operation, hunks: section.hunks,
                            additions: section.additions, deletions: section.deletions)
        }
    }

    /// `apply_patch` input: the `*** Begin Patch` envelope, or a plain unified diff.
    private static func patch(_ args: [String: JSONValue]) -> ToolFileEdit? {
        guard let raw = ["input", "patch", "diff"].lazy.compactMap({ args[$0]?.string })
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        var clipped = raw.utf16.count > Limits.maxInputCharacters
        let text = clipped ? String(decoding: raw.utf16.prefix(Limits.maxInputCharacters), as: UTF16.self) : raw
        var sections: [PatchSection] = []
        var current: PatchSection?
        var stored = 0
        var omitted = 0
        var isEnvelope = false
        var skipNext = false
        func finish() {
            if let section = current { sections.append(section) }
            current = nil
        }

        let allLines = Self.splitLines(text)
        for (index, line) in allLines.enumerated() {
            if skipNext { skipNext = false; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "...(truncated)..." { clipped = true; continue }
            if let (operation, path) = Self.envelopeHeader(trimmed) {
                finish()
                isEnvelope = true
                current = PatchSection(operation: operation, sourcePath: path, path: path)
                continue
            }
            if trimmed.hasPrefix("*** Move to: "), current?.operation == .update {
                let path = trimmed.dropFirst("*** Move to: ".count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { current?.path = path }
                continue
            }
            if trimmed.hasPrefix("*** ") { continue }
            // A plain unified diff's `--- old` / `+++ new` pair starts a file.
            if !isEnvelope, line.hasPrefix("diff --git ") { continue }
            if !isEnvelope, line.hasPrefix("--- "), index + 1 < allLines.count, allLines[index + 1].hasPrefix("+++ ") {
                finish()
                skipNext = true
                let old = Self.unifiedPath(line.dropFirst(4))
                let new = Self.unifiedPath(allLines[index + 1].dropFirst(4))
                switch (old, new) {
                case let (nil, new?): current = PatchSection(operation: .add, sourcePath: new, path: new)
                case let (old?, nil): current = PatchSection(operation: .delete, sourcePath: old, path: old)
                case let (old?, new?): current = PatchSection(operation: .update, sourcePath: old, path: new)
                case (nil, nil): break
                }
                continue
            }
            guard var section = current else { continue }
            defer { current = section }
            if line.hasPrefix("@@") {
                let (old, new) = Self.hunkStarts(line)
                section.startHunk(old: old, new: new)
                continue
            }
            let kind: DiffLine.Kind
            switch line.first {
            case "+": kind = .addition
            case "-": kind = .deletion
            case " ", nil: kind = .context
            case "\\": continue // "\ No newline at end of file"
            default: continue
            }
            if section.operation == .add, kind != .addition { continue }
            if section.operation == .delete, kind != .deletion { continue }
            let number: Int?
            switch kind {
            case .addition:
                section.additions += 1
                number = section.operation == .add ? section.additions : section.newLine
                section.newLine = section.newLine.map { $0 + 1 }
            case .deletion:
                section.deletions += 1
                number = section.operation == .delete ? section.deletions : section.oldLine
                section.oldLine = section.oldLine.map { $0 + 1 }
            case .context:
                number = section.newLine
                section.oldLine = section.oldLine.map { $0 + 1 }
                section.newLine = section.newLine.map { $0 + 1 }
            }
            if stored < Limits.maxRenderedLines {
                section.lines.append(DiffLine(kind, line.isEmpty ? "" : String(line.dropFirst()), lineNumber: number))
                stored += 1
            } else {
                omitted += 1
            }
        }
        finish()
        guard !sections.isEmpty else { return nil }
        let files = sections.map(\.file)
        guard files.contains(where: { !$0.hunks.isEmpty || $0.operation == .delete || $0.operation == .move }) else { return nil }
        // A delete with no lines listed doesn't say how many it removed.
        let headerOnlyDelete = files.contains { $0.operation == .delete && $0.deletions == 0 }
        return ToolFileEdit(kind: .patch, files: files, additionsBound: clipped ? .atLeast : .exact,
                            deletionsBound: clipped || headerOnlyDelete ? .atLeast : .exact, isTruncated: clipped, omittedLines: clipped ? nil : omitted,
                            copyText: clipped ? raw : nil)
    }

    private static func envelopeHeader(_ line: String) -> (FileDiff.Operation, String)? {
        for (prefix, operation) in [("*** Update File: ", FileDiff.Operation.update), ("*** Add File: ", .add),
                                    ("*** Delete File: ", .delete)] where line.hasPrefix(prefix)
        {
            let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : (operation, path)
        }
        return nil
    }

    /// `a/foo.swift` → `foo.swift`; `/dev/null` → nil. Drops a trailing tab-separated timestamp.
    private static func unifiedPath(_ raw: Substring) -> String? {
        var path = String(raw.split(separator: "\t", maxSplits: 1).first ?? raw).trimmingCharacters(in: .whitespaces)
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
        return path.isEmpty ? nil : path
    }

    /// Start lines of `@@ -a,b +c,d @@`, nil when the header has no numbers (envelope `@@ context`).
    private static func hunkStarts(_ line: String) -> (Int?, Int?) {
        guard let match = line.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) else { return (nil, nil) }
        return (Int(match.1), Int(match.2))
    }
}

// MARK: Line diff

/// Line diff of two texts: longest common subsequence over the lines between their common prefix
/// and suffix, with inputs capped by `ToolFileEdit.Limits`.
public enum DiffBuilder {
    public struct Result: Hashable, Sendable {
        public let hunks: [DiffHunk]
        /// An input was longer than `maxInputLines` and only its start was compared.
        public let isTruncated: Bool
    }

    /// Diffs `old` against `new`. Diffs of up to `Limits.collapseThreshold` lines come back as one
    /// hunk with every line; longer or clipped ones are cut to the changes plus `context` lines
    /// around them, one hunk per run.
    public static func diff(old: String, new: String, context: Int = ToolFileEdit.Limits.contextLines) -> Result {
        let limit = ToolFileEdit.Limits.maxInputLines
        let oldLines = ToolFileEdit.splitLines(old)
        let newLines = ToolFileEdit.splitLines(new)
        let (prefix, suffix) = self.commonEnds(oldLines, newLines)
        // Only the differing middle counts against the cap, so a small change in a big text stays exact.
        let oldMiddle = oldLines[prefix..<(oldLines.count - suffix)]
        let newMiddle = newLines[prefix..<(newLines.count - suffix)]
        let clipped = oldMiddle.count > limit || newMiddle.count > limit
        var lines = oldLines[..<prefix].map { DiffLine(.context, $0) }
        lines += self.lines(old: Array(oldMiddle.prefix(limit)), new: Array(newMiddle.prefix(limit)))
        if !clipped { lines += oldLines[(oldLines.count - suffix)...].map { DiffLine(.context, $0) } }
        // Short diffs keep every line; past the collapse threshold, a collapsed card's first rows
        // must reach the change, so trim to `context` lines around it.
        guard clipped || lines.count > ToolFileEdit.Limits.collapseThreshold else {
            return Result(hunks: lines.isEmpty ? [] : [DiffHunk(lines: lines)], isTruncated: false)
        }
        return Result(hunks: self.hunks(lines, context: context), isTruncated: clipped)
    }

    /// Every line of `old` and `new`, marked context, deletion or addition.
    public static func lines(old: [String], new: [String]) -> [DiffLine] {
        let (prefix, suffix) = self.commonEnds(old, new)
        let a = old[prefix..<(old.count - suffix)].map(\.self)
        let b = new[prefix..<(new.count - suffix)].map(\.self)

        var out = old[..<prefix].map { DiffLine(.context, $0) }
        let width = b.count + 1
        // Suffix LCS lengths; UInt16 fits the per-side cap and keeps the table small.
        var table = [UInt16](repeating: 0, count: (a.count + 1) * width)
        if !a.isEmpty, !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i * width + j] = a[i] == b[j]
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                out.append(DiffLine(.context, a[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                out.append(DiffLine(.deletion, a[i]))
                i += 1
            } else {
                out.append(DiffLine(.addition, b[j]))
                j += 1
            }
        }
        out += a[i...].map { DiffLine(.deletion, $0) }
        out += b[j...].map { DiffLine(.addition, $0) }
        out += old[(old.count - suffix)...].map { DiffLine(.context, $0) }
        return out
    }

    /// Lengths of the common leading and trailing runs, not overlapping.
    static func commonEnds(_ old: [String], _ new: [String]) -> (prefix: Int, suffix: Int) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        return (prefix, suffix)
    }

    /// The changed lines with `context` unchanged lines around each, split where they're further apart.
    public static func hunks(_ lines: [DiffLine], context: Int) -> [DiffHunk] {
        var keep = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where line.kind != .context {
            for k in max(0, index - context)..<min(lines.count, index + context + 1) { keep[k] = true }
        }
        var hunks: [DiffHunk] = []
        var current: [DiffLine] = []
        for (index, line) in lines.enumerated() {
            if keep[index] {
                current.append(line)
            } else if !current.isEmpty {
                hunks.append(DiffHunk(lines: current))
                current = []
            }
        }
        if !current.isEmpty { hunks.append(DiffHunk(lines: current)) }
        return hunks
    }

    /// Keeps at most `budget` lines across `hunks`, returning how many were dropped.
    public static func cap(_ hunks: [DiffHunk], budget: Int) -> (hunks: [DiffHunk], omitted: Int) {
        var remaining = budget
        var kept: [DiffHunk] = []
        var omitted = 0
        for hunk in hunks {
            if remaining <= 0 {
                omitted += hunk.lines.count
            } else if hunk.lines.count <= remaining {
                kept.append(hunk)
                remaining -= hunk.lines.count
            } else {
                kept.append(DiffHunk(lines: Array(hunk.lines.prefix(remaining)), oldStart: hunk.oldStart, newStart: hunk.newStart))
                omitted += hunk.lines.count - remaining
                remaining = 0
            }
        }
        return (kept, omitted)
    }
}
