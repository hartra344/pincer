import Foundation

/// Unsaved edits to the whole Gateway config, kept apart from the loaded config until saved.
/// Every settings page reads and writes through one of these, so moving between pages never
/// loses anything, and Save sends everything as a single `config.patch`.
public struct ConfigEdits: Sendable, Equatable {
    /// One changed value, for review. `old`/`new` are `nil` when the key is absent.
    public struct Change: Identifiable, Hashable, Sendable {
        public let path: [String]
        public let old: JSONValue?
        public let new: JSONValue?
        public var id: String { ConfigPath.string(self.path) }
    }

    /// An edit whose value also changed on the Gateway since it was made.
    public struct Conflict: Identifiable, Hashable, Sendable {
        public let path: [String]
        /// What the Gateway has now.
        public let theirs: JSONValue?
        /// What this draft sets.
        public let mine: JSONValue?
        public var id: String { ConfigPath.string(self.path) }
    }

    /// The loaded config the edits apply to.
    public private(set) var base: JSONValue
    /// Values set by path; `.null` removes the key. No entry is an ancestor of another.
    public private(set) var edits: [[String]: JSONValue] = [:]
    /// What was typed into text fields, by dotted path, even when it doesn't parse yet.
    public var texts: [String: String] = [:]
    /// Typed text that doesn't parse, by dotted path. Saving waits until these are fixed.
    public var inputErrors: [String: String] = [:]

    public init(base: JSONValue = .object([:])) {
        self.base = base
    }

    public var hasChanges: Bool { !self.edits.isEmpty }

    /// The whole config as it would be saved.
    public var current: JSONValue {
        self.edits.keys.sorted { $0.count < $1.count }.reduce(self.base) { config, path in
            config.setting(self.edits[path]!, at: path)
        }
    }

    /// The value at `path` with the edits applied; `nil` when absent.
    public func value(at path: [String]) -> JSONValue? {
        if let ancestor = self.edits.keys.first(where: { path.starts(with: $0) }) {
            let value = self.edits[ancestor]!
            return value.isNull ? nil : value.value(at: Array(path.dropFirst(ancestor.count)))
        }
        var value = self.base.value(at: path) ?? .null
        let below = self.edits.keys.filter { $0.count > path.count && $0.starts(with: path) }.sorted { $0.count < $1.count }
        for edit in below {
            value = value.setting(self.edits[edit]!, at: Array(edit.dropFirst(path.count)))
        }
        return value.isNull ? JSONValue?.none : value
    }

    public func baseValue(at path: [String]) -> JSONValue? {
        let value = self.base.value(at: path)
        return value?.isNull == true ? nil : value
    }

    /// Sets the value at `path`; `nil` removes the key. Setting the loaded value drops the edit.
    public mutating func set(_ path: [String], _ value: JSONValue?) {
        let new = value ?? .null
        if let ancestor = self.edits.keys.first(where: { path.count > $0.count && path.starts(with: $0) }) {
            // Inside something already replaced (e.g. a new map entry): edit that value instead.
            let updated = self.edits[ancestor]!.setting(new, at: Array(path.dropFirst(ancestor.count)))
            self.store(updated, at: ancestor)
            return
        }
        for edit in self.edits.keys where edit.count > path.count && edit.starts(with: path) {
            self.edits.removeValue(forKey: edit)
        }
        self.store(new, at: path)
    }

    private mutating func store(_ value: JSONValue, at path: [String]) {
        if (self.base.value(at: path) ?? .null) == value {
            self.edits.removeValue(forKey: path)
        } else {
            self.edits[path] = value
        }
    }

    /// Puts back the loaded value at `path` and everything under it.
    public mutating func revert(_ path: [String]) {
        self.set(path, self.baseValue(at: path))
        let prefix = ConfigPath.string(path)
        for key in self.texts.keys where Self.key(key, isUnder: prefix) { self.texts.removeValue(forKey: key) }
        for key in self.inputErrors.keys where Self.key(key, isUnder: prefix) { self.inputErrors.removeValue(forKey: key) }
    }

    public mutating func discardAll() {
        self.edits = [:]
        self.texts = [:]
        self.inputErrors = [:]
    }

    static func key(_ key: String, isUnder prefix: String) -> Bool {
        prefix.isEmpty || key == prefix || key.hasPrefix(prefix + ".")
    }

    // MARK: Review

    /// Every changed value, down to the leaves.
    public var changes: [Change] {
        var changes: [Change] = []
        Self.collect(from: self.base, to: self.current, at: [], into: &changes)
        return changes
    }

    private static func collect(from old: JSONValue?, to new: JSONValue?, at path: [String], into changes: inout [Change]) {
        let old = old?.isNull == true ? nil : old
        let new = new?.isNull == true ? nil : new
        guard old != new else { return }
        if case let .object(lhs)? = old, case let .object(rhs)? = new, !(lhs.isEmpty && rhs.isEmpty) {
            for key in Set(lhs.keys).union(rhs.keys).sorted() {
                Self.collect(from: lhs[key], to: rhs[key], at: path + [key], into: &changes)
            }
            return
        }
        changes.append(Change(path: path, old: old, new: new))
    }

    /// Number of changed values at or under `path`.
    public func changeCount(under path: [String]) -> Int {
        self.changes.count(where: { $0.path.starts(with: path) || path.starts(with: $0.path) })
    }

    public func isChanged(_ path: [String]) -> Bool {
        self.edits.keys.contains { $0.starts(with: path) || path.starts(with: $0) }
            && self.value(at: path) != self.baseValue(at: path)
    }

    // MARK: Saving

    /// RFC 7386 merge patch from the loaded config to the edited one.
    public var patch: JSONValue? {
        guard self.hasChanges else { return nil }
        let patch = JSONValue.mergeDiff(from: self.base, to: self.current)
        return patch.isEmptyObject ? JSONValue?.none : patch
    }

    /// Arrays the patch replaces or deletes. The Gateway refuses to drop array entries unless the
    /// exact path is listed, and merges arrays of `id`ed objects by ID when it isn't.
    public var replacePaths: [String] {
        guard let patch = self.patch else { return [] }
        var paths: [String] = []
        Self.arrays(in: patch, base: self.base, at: [], into: &paths)
        return paths
    }

    private static func arrays(in patch: JSONValue, base: JSONValue?, at path: [String], into paths: inout [String]) {
        switch patch {
        case let .object(values):
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                Self.arrays(in: value, base: base?[key], at: path + [key], into: &paths)
            }
        case .array:
            if !path.isEmpty { paths.append(ConfigPath.string(path)) }
        case .null:
            Self.deletedArrays(in: base, at: path, into: &paths)
        default:
            break
        }
    }

    private static func deletedArrays(in value: JSONValue?, at path: [String], into paths: inout [String]) {
        switch value {
        case .array?: paths.append(ConfigPath.string(path))
        case let .object(values)?:
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                Self.deletedArrays(in: value, at: path + [key], into: &paths)
            }
        default: break
        }
    }

    // MARK: Rebasing

    /// Moves the edits onto a newer loaded config. Edits are kept; the ones whose value also
    /// changed on the Gateway (to something else) are returned so the user can pick.
    @discardableResult
    public mutating func rebase(onto newBase: JSONValue) -> [Conflict] {
        let old = self.base
        let edits = self.edits
        self.base = newBase
        self.edits = [:]
        var conflicts: [Conflict] = []
        for (path, value) in edits.sorted(by: { $0.key.count < $1.key.count }) {
            let theirs = newBase.value(at: path)
            if (old.value(at: path) ?? .null) != (theirs ?? .null), (theirs ?? .null) != value {
                conflicts.append(Conflict(path: path, theirs: theirs?.isNull == true ? nil : theirs,
                                          mine: value.isNull ? JSONValue?.none : value))
            }
            self.store(value, at: path)
        }
        return conflicts.sorted { $0.id < $1.id }
    }
}

public extension JSONValue {
    /// This value with `value` set at `path`, creating objects on the way; `.null` removes the key.
    func setting(_ value: JSONValue, at path: [String]) -> JSONValue {
        guard let key = path.first else { return value }
        if case var .array(items) = self, let index = Int(key), items.indices.contains(index) {
            items[index] = items[index].setting(value, at: Array(path.dropFirst()))
            return .array(items)
        }
        var object = self.object ?? [:]
        let rest = Array(path.dropFirst())
        if rest.isEmpty, value.isNull {
            object.removeValue(forKey: key)
        } else {
            object[key] = (object[key] ?? .null).setting(value, at: rest)
        }
        return .object(object)
    }

    /// The RFC 7386 merge patch that turns `old` into `new`.
    static func mergeDiff(from old: JSONValue?, to new: JSONValue?) -> JSONValue {
        guard let new, !new.isNull else { return .null }
        guard case let .object(lhs)? = old, case let .object(rhs) = new else { return new }
        var patch: [String: JSONValue] = [:]
        for key in Set(lhs.keys).union(rhs.keys) {
            let before = lhs[key]
            let after = rhs[key]
            if before == after { continue }
            if after == nil {
                patch[key] = .null
            } else if case .object? = before, case .object? = after {
                let inner = Self.mergeDiff(from: before, to: after)
                if !inner.isEmptyObject { patch[key] = inner }
            } else {
                patch[key] = after
            }
        }
        return .object(patch)
    }
}
