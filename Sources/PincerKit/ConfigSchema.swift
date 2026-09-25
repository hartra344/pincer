import Foundation

// Gateway config model: the JSON Schema and UI hints from `config.schema`, the fields a form
// shows for one object in the config, input parsing and validation, and RFC 7386 merge patches
// for `config.patch`. Pure values, so they are checked in PincerChecks without a Gateway.

public enum ConfigPath {
    /// Dotted path, as the Gateway uses in `uiHints` keys and validation issues.
    public static func string(_ path: [String]) -> String { path.joined(separator: ".") }

    public static func parse(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }

    static func humanized(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for character in key {
            if character == "_" || character == "-" || character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return key }
        let rest = words.dropFirst().map { $0.count > 1 && $0 == $0.uppercased() ? $0 : $0.lowercased() }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + rest).joined(separator: " ")
    }
}

public extension JSONValue {
    /// The Gateway replaces secrets with this in `config.get`, and restores them on write.
    static let redactedSentinel = "__OPENCLAW_REDACTED__"

    var isRedacted: Bool { self.string == Self.redactedSentinel }

    func value(at path: [String]) -> JSONValue? {
        var current: JSONValue? = self
        for key in path {
            if let index = Int(key), case .array = current { current = current?[index] } else { current = current?[key] }
        }
        return current
    }

    /// A merge patch that sets `value` at `path`; `.null` deletes the key.
    static func mergePatch(setting value: JSONValue, at path: [String]) -> JSONValue {
        path.reversed().reduce(value) { inner, key in .object([key: inner]) }
    }

    /// RFC 7386: objects merge key by key, `null` deletes, anything else replaces.
    func applyingMergePatch(_ patch: JSONValue) -> JSONValue {
        guard case let .object(changes) = patch else { return patch }
        var result = self.object ?? [:]
        for (key, change) in changes {
            if change.isNull {
                result.removeValue(forKey: key)
            } else {
                result[key] = (result[key] ?? .null).applyingMergePatch(change)
            }
        }
        return .object(result)
    }

    /// Deep merge of two merge patches (the right side wins on conflicts).
    func mergingPatch(_ other: JSONValue) -> JSONValue {
        guard case let .object(lhs) = self, case let .object(rhs) = other else { return other }
        return .object(lhs.merging(rhs) { $0.mergingPatch($1) })
    }

    var isEmptyObject: Bool { self.object?.isEmpty == true }

    func prettyPrinted() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func compactString() -> String {
        guard let data = try? self.encoded() else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One validation problem reported by the Gateway (`config.get` issues, or a rejected write).
public struct ConfigIssue: Identifiable, Hashable, Sendable {
    public let path: String
    public let message: String
    public let fixHint: String?
    public var id: String { "\(self.path)|\(self.message)" }

    public init(path: String, message: String, fixHint: String? = nil) {
        self.path = path
        self.message = message
        self.fixHint = fixHint
    }

    init?(_ json: JSONValue) {
        guard let message = json["message"]?.text else { return nil }
        if let parts = json["path"]?.array {
            self.path = parts.compactMap { $0.string ?? $0.int.map(String.init) }.joined(separator: ".")
        } else {
            self.path = json["path"]?.string ?? ""
        }
        self.message = message
        self.fixHint = json["fixHint"]?.text
    }

    public static func list(_ json: JSONValue?) -> [ConfigIssue] {
        json?.array?.compactMap(ConfigIssue.init) ?? []
    }

    /// Issues attached to a failed write (`details.issues`); falls back to the error message.
    public static func from(_ error: Error) -> [ConfigIssue] {
        guard case let GatewayError.rpc(_, message, details) = error else { return [] }
        let issues = Self.list(details?["issues"])
        return issues.isEmpty ? [ConfigIssue(path: "", message: message)] : issues
    }

    public var displayPath: String { self.path.isEmpty ? "Config" : self.path }
}

public struct ConfigField: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text
        case secret
        case integer
        case number
        case toggle
        case choice([String])
        /// A list of strings, edited one per line.
        case list
        /// A nested object, edited on its own page.
        case object
        /// Anything the form can't model, edited as JSON.
        case json
    }

    public let path: [String]
    public let label: String
    public let help: String?
    public let placeholder: String?
    public let kind: Kind
    public let isRequired: Bool
    public let isAdvanced: Bool
    public let order: Double
    public let minimum: Double?
    public let maximum: Double?
    public let minLength: Int?
    public let pattern: String?
    public let defaultValue: JSONValue?
    /// Object whose keys are user-defined (a map), such as `plugins.entries`.
    public let isMap: Bool
    /// Where to get a credential, for plugin credentials.
    public var signupURL: URL? = nil

    public var id: String { ConfigPath.string(self.path) }
    public var key: String { self.path.last ?? "" }

    /// A secret field for a credential a plugin declares, merged with the schema's field if any.
    public static func credential(_ credential: PluginCredential, existing: ConfigField?) -> ConfigField {
        var help = existing?.help
        if !credential.envVars.isEmpty {
            let env = "Or set \(credential.envVars.joined(separator: " or ")) on the Gateway host."
            help = help.map { "\($0) \(env)" } ?? env
        }
        return ConfigField(
            path: credential.path,
            label: credential.label,
            help: help,
            placeholder: credential.placeholder ?? existing?.placeholder,
            kind: .secret,
            isRequired: credential.isRequired || (existing?.isRequired ?? false),
            isAdvanced: false,
            order: -1,
            minimum: nil,
            maximum: nil,
            minLength: existing?.minLength,
            pattern: existing?.pattern,
            defaultValue: nil,
            isMap: false,
            signupURL: credential.signupURL)
    }

    /// Editable text for a value.
    public func text(for value: JSONValue?) -> String {
        guard let value, !value.isNull else { return "" }
        switch self.kind {
        case .text, .secret, .choice: return value.string ?? value.compactString()
        case .integer, .number:
            if let number = value.double {
                return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            }
            return value.string ?? ""
        case .list: return (value.array ?? []).map { $0.string ?? $0.compactString() }.joined(separator: "\n")
        case .toggle: return value.bool.map { $0 ? "true" : "false" } ?? ""
        case .object, .json: return value.prettyPrinted()
        }
    }

    public struct InputError: Error, Equatable, Sendable, LocalizedError {
        public let message: String
        public var errorDescription: String? { self.message }
    }

    /// Parses user input into a config value. `nil` means "not set" (the key is removed).
    public func value(fromText text: String) throws(InputError) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, self.kind != .toggle { return nil }
        switch self.kind {
        case .text, .secret, .choice:
            return .string(self.kind == .secret ? text : trimmed)
        case .integer:
            guard let number = Int64(trimmed) else { throw InputError(message: "Enter a whole number.") }
            return .number(Double(number))
        case .number:
            guard let number = Double(trimmed), number.isFinite else { throw InputError(message: "Enter a number.") }
            return .number(number)
        case .toggle:
            return .bool(trimmed == "true")
        case .list:
            let items = trimmed.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .array(items.map(JSONValue.string))
        case .object, .json:
            guard let data = trimmed.data(using: .utf8), let value = try? JSONValue.decode(data) else {
                throw InputError(message: "Enter valid JSON.")
            }
            return value
        }
    }

    /// Client-side check before sending; the Gateway still validates the whole config.
    public func validate(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return self.isRequired ? "\(self.label) is required." : nil }
        if value.isRedacted { return nil }
        switch self.kind {
        case .text, .secret:
            guard let string = value.string else { return nil }
            if self.isRequired, string.trimmingCharacters(in: .whitespaces).isEmpty { return "\(self.label) is required." }
            if let minLength = self.minLength, string.count < minLength {
                return "Use at least \(minLength) character\(minLength == 1 ? "" : "s")."
            }
            if let pattern = self.pattern, let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil
            {
                return "Doesn't match the expected format (\(pattern))."
            }
        case .integer, .number:
            guard let number = value.double else { return "Enter a number." }
            if self.kind == .integer, number.rounded() != number { return "Enter a whole number." }
            if let minimum = self.minimum, number < minimum { return "Must be at least \(Self.format(minimum))." }
            if let maximum = self.maximum, number > maximum { return "Must be at most \(Self.format(maximum))." }
        case let .choice(options):
            if let string = value.string, !options.contains(string) {
                return "Choose one of: \(options.joined(separator: ", "))."
            }
        case .toggle, .list, .object, .json:
            break
        }
        return nil
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int64(number)) : String(number)
    }
}

/// The `config.schema` payload: JSON Schema plus UI hints (labels, help, `sensitive`, order).
public struct ConfigSchema: Sendable {
    public let root: JSONValue
    public let hints: [String: JSONValue]
    public let version: String?

    public init(schema: JSONValue, hints: [String: JSONValue] = [:], version: String? = nil) {
        self.root = schema
        self.hints = hints
        self.version = version
    }

    public init(response: JSONValue) {
        self.init(schema: response["schema"] ?? .object([:]),
                  hints: response["uiHints"]?.object ?? [:],
                  version: response["version"]?.text)
    }

    // MARK: Nodes

    /// Follows local `$ref`s and merges `allOf`.
    func resolve(_ node: JSONValue) -> JSONValue {
        var node = node
        var hops = 0
        while let ref = node["$ref"]?.string, ref.hasPrefix("#/"), hops < 16 {
            let target = self.root.value(at: ConfigPath.parse(String(ref.dropFirst(2)).replacingOccurrences(of: "/", with: ".")))
            guard let target else { break }
            var merged = target.object ?? [:]
            for (key, value) in node.object ?? [:] where key != "$ref" { merged[key] = value }
            node = .object(merged)
            hops += 1
        }
        if let parts = node["allOf"]?.array, !parts.isEmpty {
            var merged = node.object ?? [:]
            merged.removeValue(forKey: "allOf")
            var properties = merged["properties"]?.object ?? [:]
            var required = Set(merged["required"]?.array?.compactMap(\.string) ?? [])
            for part in parts.map(self.resolve) {
                for (key, value) in part.object ?? [:] where key != "properties" && key != "required" && merged[key] == nil {
                    merged[key] = value
                }
                properties.merge(part["properties"]?.object ?? [:]) { lhs, _ in lhs }
                required.formUnion(part["required"]?.array?.compactMap(\.string) ?? [])
            }
            if !properties.isEmpty { merged["properties"] = .object(properties) }
            if !required.isEmpty { merged["required"] = JSONValue(required.sorted()) }
            node = .object(merged)
        }
        return node
    }

    private func branches(_ node: JSONValue) -> [JSONValue] {
        (node["anyOf"]?.array ?? node["oneOf"]?.array ?? []).map(self.resolve)
    }

    private func types(_ node: JSONValue) -> [String] {
        if let type = node["type"]?.string { return [type] }
        return node["type"]?.array?.compactMap(\.string) ?? []
    }

    private func isObjectNode(_ node: JSONValue) -> Bool {
        self.types(node).contains("object") || node["properties"] != nil
            || (node["additionalProperties"]?.object != nil && self.types(node).isEmpty)
    }

    /// The object branch of a union, for descending into children.
    private func objectBranch(_ node: JSONValue) -> JSONValue? {
        let node = self.resolve(node)
        if self.isObjectNode(node) { return node }
        return self.branches(node).first(where: self.isObjectNode)
    }

    private func child(of parent: JSONValue, key: String) -> JSONValue? {
        guard let object = self.objectBranch(parent) else {
            let resolved = self.resolve(parent)
            if self.types(resolved).contains("array") || resolved["items"] != nil, Int(key) != nil {
                return resolved["items"].map(self.resolve)
            }
            return nil
        }
        if let property = object["properties"]?[key] { return self.resolve(property) }
        if let pattern = object["patternProperties"]?.object?.values.first { return self.resolve(pattern) }
        if let additional = object["additionalProperties"], additional.object != nil { return self.resolve(additional) }
        return nil
    }

    public func node(at path: [String]) -> JSONValue? {
        var current: JSONValue? = self.resolve(self.root)
        for key in path {
            guard let node = current else { return nil }
            current = self.child(of: node, key: key)
        }
        return current
    }

    // MARK: Hints

    /// Exact hint first, then one whose `*` / `[]` segments match.
    public func hint(for path: [String]) -> JSONValue? {
        if let exact = self.hints[ConfigPath.string(path)] { return exact }
        var best: (score: Int, hint: JSONValue)?
        for (key, hint) in self.hints {
            let pattern = ConfigPath.parse(key.replacingOccurrences(of: "[]", with: ".*"))
            guard pattern.count == path.count else { continue }
            var score = 0
            var matches = true
            for (lhs, rhs) in zip(pattern, path) {
                if lhs == rhs { score += 1 } else if lhs != "*" { matches = false; break }
            }
            if matches, score > (best?.score ?? -1) { best = (score, hint) }
        }
        return best?.hint
    }

    public func isSensitive(_ path: [String]) -> Bool {
        if self.hint(for: path)?["sensitive"]?.bool == true { return true }
        let key = path.last?.lowercased() ?? ""
        return ["token", "apikey", "api_key", "password", "secret", "clientsecret", "privatekey"].contains(key)
            || key.hasSuffix("token") || key.hasSuffix("apikey") || key.hasSuffix("secret") || key.hasSuffix("password")
    }

    // MARK: Fields

    public func field(at path: [String], node: JSONValue? = nil, required: Bool = false, value: JSONValue? = nil) -> ConfigField? {
        guard let node = node ?? self.node(at: path) else { return nil }
        let hint = self.hint(for: path)
        var resolved = self.resolve(node)
        // An open schema (`{}`) says nothing about the type; go by the value that's there.
        if let value, !value.isNull, !self.hasTypeInfo(resolved) {
            resolved = resolved.applyingMergePatch(Self.inferredNode(for: value))
        }
        let concrete = self.concreteBranch(resolved, value: value)
        var kind = self.kind(of: concrete, path: path)
        // A value the form can't show as its kind (e.g. a SecretRef object) is edited as JSON.
        if let value, !value.isNull, !value.isRedacted, !Self.fits(value, kind) { kind = .json }
        let isMap = kind == .object && concrete["properties"] == nil
            && (concrete["additionalProperties"]?.object != nil || concrete["patternProperties"] != nil)
        return ConfigField(
            path: path,
            label: hint?["label"]?.text ?? resolved["title"]?.text ?? ConfigPath.humanized(path.last ?? "Config"),
            help: hint?["help"]?.text ?? resolved["description"]?.text,
            placeholder: hint?["placeholder"]?.text,
            kind: kind,
            isRequired: required,
            isAdvanced: hint?["advanced"]?.bool ?? false,
            order: hint?["order"]?.double ?? .greatestFiniteMagnitude,
            minimum: concrete["minimum"]?.double ?? concrete["exclusiveMinimum"]?.double,
            maximum: concrete["maximum"]?.double ?? concrete["exclusiveMaximum"]?.double,
            minLength: concrete["minLength"]?.int,
            pattern: concrete["pattern"]?.string,
            defaultValue: resolved["default"] ?? concrete["default"],
            isMap: isMap)
    }

    /// The fields of the object at `path`: its declared properties, plus any keys already in
    /// `value` for map-like objects (e.g. one entry per plugin under `plugins.entries`).
    public func fields(at path: [String], value: JSONValue?) -> [ConfigField] {
        let node: JSONValue? = path.isEmpty ? self.resolve(self.root) : self.node(at: path)
        guard let node, let object = self.objectBranch(node) else { return [] }
        let required = Set(object["required"]?.array?.compactMap(\.string) ?? [])
        var fields: [ConfigField] = []
        var seen = Set<String>()
        for (key, property) in object["properties"]?.object ?? [:] {
            seen.insert(key)
            if let field = self.field(at: path + [key], node: property, required: required.contains(key),
                                      value: value?[key]) {
                fields.append(field)
            }
        }
        let extra = object["additionalProperties"].flatMap { $0.object != nil ? $0 : nil }
            ?? object["patternProperties"]?.object?.values.first
        for (key, child) in value?.object ?? [:] where !seen.contains(key) {
            let childNode = extra ?? Self.inferredNode(for: child)
            if let field = self.field(at: path + [key], node: childNode, value: child) { fields.append(field) }
        }
        return fields.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.isRequired != rhs.isRequired { return lhs.isRequired }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }
    }

    /// Checks each field of the object at `path` against the draft value of that object.
    public func validate(object value: JSONValue?, at path: [String]) -> [String: String] {
        var problems: [String: String] = [:]
        for field in self.fields(at: path, value: value) where field.kind != .object {
            if let problem = field.validate(value?[field.key]) { problems[field.id] = problem }
        }
        return problems
    }

    private func concreteBranch(_ node: JSONValue, value: JSONValue?) -> JSONValue {
        let branches = self.branches(node).filter { !self.types($0).elementsEqual(["null"]) }
        guard !branches.isEmpty, node["type"] == nil else { return node }
        // Unions of literals are a choice.
        let literals = branches.compactMap { $0["const"]?.string ?? ($0["enum"]?.array?.count == 1 ? $0["enum"]?[0]?.string : nil) }
        if literals.count == branches.count {
            return .object(["type": "string", "enum": JSONValue(literals)])
        }
        if let value, !value.isNull,
           let match = branches.first(where: { Self.fits(value, self.kind(of: $0, path: [])) })
        {
            return match
        }
        return branches.first { !self.isObjectNode($0) } ?? branches[0]
    }

    private func hasTypeInfo(_ node: JSONValue) -> Bool {
        ["type", "enum", "const", "properties", "anyOf", "oneOf", "items", "additionalProperties"].contains { node[$0] != nil }
    }

    private func kind(of node: JSONValue, path: [String]) -> ConfigField.Kind {
        if let options = node["enum"]?.array?.compactMap(\.string), !options.isEmpty { return .choice(options) }
        let types = self.types(node).filter { $0 != "null" }
        if types.count == 1 {
            switch types[0] {
            case "boolean": return .toggle
            case "integer": return .integer
            case "number": return .number
            case "string": return self.isSensitive(path) ? .secret : .text
            case "array":
                let items = node["items"].map(self.resolve)
                return items.map { self.types($0) == ["string"] && $0["enum"] == nil } == true ? .list : .json
            case "object": return .object
            default: return .json
            }
        }
        if types.isEmpty, self.isObjectNode(node) { return .object }
        return .json
    }

    static func fits(_ value: JSONValue, _ kind: ConfigField.Kind) -> Bool {
        switch (kind, value) {
        case (.text, .string), (.secret, .string), (.choice, .string), (.toggle, .bool),
             (.integer, .number), (.number, .number), (.object, .object), (.json, _):
            return true
        case (.list, .array(let items)):
            return items.allSatisfy { $0.string != nil }
        default:
            return false
        }
    }

    private static func inferredNode(for value: JSONValue) -> JSONValue {
        switch value {
        case .bool: ["type": "boolean"]
        case .number: ["type": "number"]
        case .string: ["type": "string"]
        case .object: ["type": "object", "additionalProperties": .object([:])]
        default: .object([:])
        }
    }
}

/// Edits to one object in the config, kept apart from the loaded value until saved.
public struct ConfigDraft: Sendable, Equatable {
    public let path: [String]
    public let original: JSONValue?
    /// Changed keys: a value to set, or `.null` to remove.
    public private(set) var changes: [String: JSONValue] = [:]

    public init(path: [String], original: JSONValue?) {
        self.path = path
        self.original = original
    }

    public var hasChanges: Bool { !self.changes.isEmpty }

    public func value(for key: String) -> JSONValue? {
        if let change = self.changes[key] { return change.isNull ? nil : change }
        return self.original?[key]
    }

    /// The object as it would be saved.
    public var current: JSONValue {
        (self.original ?? .object([:])).applyingMergePatch(.object(self.changes))
    }

    public mutating func set(_ key: String, _ value: JSONValue?) {
        let old = self.original?[key]
        let new = value ?? .null
        if (old ?? .null) == new || (old == nil && new.isNull) {
            self.changes.removeValue(forKey: key)
        } else {
            self.changes[key] = new
        }
    }

    public mutating func reset() { self.changes = [:] }

    /// Merge patch for `config.patch`, rooted at the config top.
    public var patch: JSONValue? {
        guard self.hasChanges else { return nil }
        return .mergePatch(setting: .object(self.changes), at: self.path)
    }
}
