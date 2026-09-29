import Foundation
import Testing

/// Issue #58: the String Catalog at `Sources/PincerUI/Resources/Localizable.xcstrings` is valid,
/// English-sourced, complete, and every `bundle: .module` key in PincerUI exists in it. Reads repo
/// files via `#filePath`, so it runs under `swift test` without PincerUI.
@Suite("Localization catalog")
struct LocalizationCatalogTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let catalogURL = root.appending(path: "Sources/PincerUI/Resources/Localizable.xcstrings")

    func loadCatalog() throws -> (data: Data, json: [String: Any]) {
        let data = try Data(contentsOf: Self.catalogURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "catalog is a JSON object")
        return (data, json)
    }

    func strings() throws -> [String: [String: Any]] {
        let raw = try #require(try self.loadCatalog().json["strings"] as? [String: Any], "catalog has a strings object")
        return raw.mapValues { $0 as? [String: Any] ?? [:] }
    }

    @Test func catalogExistsAndIsEnglishSourced() throws {
        #expect(FileManager.default.fileExists(atPath: Self.catalogURL.path(percentEncoded: false)), "missing \(Self.catalogURL.path)")
        let json = try self.loadCatalog().json
        #expect(json["sourceLanguage"] as? String == "en")
        #expect((json["version"] as? String).map { !$0.isEmpty } == true, "catalog has a version")
        #expect(!(try self.strings()).isEmpty, "catalog has strings")
    }

    @Test func coreControlsAreInTheCatalog() throws {
        let keys = Set(try self.strings().keys)
        let core = ["Send", "Stop", "Attach files", "Model", "Context window", "Find next", "Find previous",
                    "Copy", "Reply", "Add Reaction", "Cancel", "Done"]
        let missing = core.filter { !keys.contains($0) }
        #expect(missing.isEmpty, "core control keys missing from the catalog: \(missing)")
    }

    @Test func packageDeclaresEnglishDefaultLocalization() throws {
        let manifest = try String(contentsOf: Self.root.appending(path: "Package.swift"), encoding: .utf8)
        #expect(manifest.contains(/defaultLocalization:\s*"en"/), "Package.swift sets defaultLocalization: \"en\"")
        #expect(manifest.contains(/resources:\s*\[[^\]]*Resources/) || manifest.contains(/\.process\(\s*"Resources/),
                "PincerUI processes its Resources folder")
    }

    @Test func noDuplicateOrEmptyKeys() throws {
        let data = try self.loadCatalog().data
        let duplicates = try StrictJSON.duplicateKeys(in: data)
        #expect(duplicates.isEmpty, "duplicate JSON keys: \(duplicates)")
        let keys = try self.strings().keys
        #expect(!keys.contains(""), "empty catalog key")
        let blank = keys.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(blank.isEmpty, "whitespace-only keys: \(blank)")
    }

    @Test func everyKeyHasANonEmptyEnglishValue() throws {
        var problems: [String] = []
        for (key, entry) in try self.strings() {
            if entry["shouldTranslate"] as? Bool == false { continue }
            let values = Catalog.englishValues(entry)
            if values.isEmpty {
                problems.append("\(key): no en stringUnit")
            } else if values.contains(where: { $0.value.isEmpty }) {
                problems.append("\(key): empty en value")
            }
        }
        #expect(problems.isEmpty, "\(problems.sorted())")
    }

    @Test func formatSpecifiersMatchBetweenKeyAndValue() throws {
        var problems: [String] = []
        for (key, entry) in try self.strings() {
            let expected = FormatSpecifiers.parse(key)
            for (path, value) in Catalog.englishValues(entry) {
                let actual = FormatSpecifiers.parse(value)
                // A plural variation may drop the count ("One message") but must not add or retype one.
                let isVariation = path != "stringUnit"
                let ok = isVariation ? actual.allSatisfy { expected[$0.key] == $0.value } : actual == expected
                if !ok { problems.append("\(key) [\(path)]: key \(expected) vs value \(actual) (\(value))") }
            }
        }
        #expect(problems.isEmpty, "\(problems.sorted())")
    }

    @Test func formatSpecifierParser() {
        #expect(FormatSpecifiers.parse("Hello") == [:])
        #expect(FormatSpecifiers.parse("%@ sent %lld messages") == [1: "@", 2: "lld"])
        #expect(FormatSpecifiers.parse("%2$lld from %1$@") == [1: "@", 2: "lld"])
        #expect(FormatSpecifiers.parse("100%% done") == [:])
        #expect(FormatSpecifiers.parse("%.1f%%") == [1: "f"])
        #expect(FormatSpecifiers.parse("%1$@ %@") != FormatSpecifiers.parse("%@ %lld"))
    }

    @Test func strictJSONFindsDuplicates() throws {
        #expect(try StrictJSON.duplicateKeys(in: Data(#"{"a":1,"b":{"c":1,"c":2},"a":[{"x":1,"x":1}]}"#.utf8)).sorted()
            == ["a", "b.c", "a[0].x"].sorted())
        #expect(try StrictJSON.duplicateKeys(in: Data(#"{"a\"b":"}\"","c":[1,true,null,-2.5e3]}"#.utf8)).isEmpty)
    }

    @Test func sourceScanFindsModuleBundleKeys() throws {
        let source = #"""
        // Use Text("comment", bundle: .module) here
        Text("Send", bundle: .module)
        let a = L("Copy link")
        Label(L("Pinned \(count)"), systemImage: "pin")
        Text(l: "Say \"hi\"")
        String(localized: "Retry", table: "Localizable", bundle: .module)
        let url = URL("not a key")
        Text("Plain")
        /* Text(l: "block comment") */
        let raw = #"L("raw")"#
        Composer(placeholder: L("Message #\(row?.title ?? L("chat"))"))
        """#
        let keys = try SourceScan.keys(in: source, file: "X.swift").map(\.key)
        #expect(keys == ["Send", "Copy link", #"Pinned \(count)"#, #"Say "hi""#, "Retry", "chat", #"Message #\(row?.title ?? L("chat"))"#])
        let pattern = try #require(SourceScan.interpolationPattern(#"Pinned \(count) of \(total.formatted())"#))
        #expect("Pinned %lld of %@".wholeMatch(of: pattern) != nil)
        #expect("Pinned %1$lld of %2$@".wholeMatch(of: pattern) != nil)
        #expect("Pinned 3 of %@".wholeMatch(of: pattern) == nil)
    }

    /// Files migrated to the catalog for #58 keep looking their strings up in PincerUI's bundle.
    /// (Theme.swift is migrated too, but only through `AccessibilityAnnouncer.announceCopied()`.)
    @Test func migratedFilesUseTheCatalog() throws {
        let migrated = [
            "Composer", "SlashCommandMenu", "ModelPicker", "ContextMeter", "TranscriptFind", "SettingsPages",
            "SettingsFields", "AvatarSettingsSection", "MenuBarSettingsSection", "QuickCaptureSettingsSection",
            "QuickCaptureView", "LaunchAtLoginSettingsSection", "UsagePage", "UsageComponents", "SessionUsagePage",
            "ApprovalHistoryPage", "ExecPolicyPage", "GatewayLogsPage", "PairingRequestsPage", "ReactionPicker",
            "QuestionCardView", "ProgressCardView", "TipsOverlay", "AutomationsView", "SkillsViews",
            "ToolsInspectorViews", "AgentManagementViews", "MenuBarExtra", "ChatView", "PluginSettings",
            "ThinkingDisplay", "ImageViews", "DevicesPage", "ChannelStatusPage", "ChannelQRLoginView",
            "FullManagementBadge", "GatewayHealthPage", "RunTimelineView", "RunsPanel", "SubagentTreeView",
            // #191, #192, #351
            "ConnectionViews", "FirstRunView", "SetupWizardView", "RootView", "CommandPaletteView",
            "GatewaySettingsWindow", "DeepLinkRouting", "SidebarList+AppKit", "SidebarSupport", "ChannelList",
            "TranscriptRowLayout", "TranscriptRowView+Parts",
        ]
        let folder = Self.root.appending(path: "Sources/PincerUI")
        var unmigrated: [String] = []
        for name in migrated {
            let text = try String(contentsOf: folder.appending(path: "\(name).swift"), encoding: .utf8)
            if try SourceScan.keys(in: text, file: name).isEmpty { unmigrated.append(name) }
        }
        #expect(unmigrated.isEmpty, "migrated files with no catalog lookups: \(unmigrated)")
    }

    /// Every literal key passed with `bundle: .module` in PincerUI, or to PincerKit's `L("…")` (whose
    /// sentences live in PincerUI's catalog, #193 #228 #295), must be in the catalog, or the raw
    /// English key shows at runtime in other locales.
    @Test func everyModuleBundleKeyInPincerUIIsInTheCatalog() throws {
        let keys = Set(try self.strings().keys)
        let usages = try SourceScan.moduleBundleKeys(in: Self.root.appending(path: "Sources/PincerUI"))
            + SourceScan.moduleBundleKeys(in: Self.root.appending(path: "Sources/PincerKit"))
        var missing: [String] = []
        for usage in usages where !keys.contains(usage.key) {
            let pattern = SourceScan.interpolationPattern(usage.key)
            if let pattern, keys.contains(where: { $0.wholeMatch(of: pattern) != nil }) { continue }
            missing.append("\(usage.file):\(usage.line) \"\(usage.key)\"")
        }
        #expect(missing.isEmpty, "keys used with bundle: .module but missing from the catalog: \(missing)")
    }
}

enum Catalog {
    /// The `en` string units of an entry: `stringUnit` plus any plural/device variations, by path.
    static func englishValues(_ entry: [String: Any]) -> [(path: String, value: String)] {
        guard let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        func walk(_ node: [String: Any], _ path: String) {
            if let unit = node["stringUnit"] as? [String: Any] {
                out.append((path.isEmpty ? "stringUnit" : path, unit["value"] as? String ?? ""))
            }
            if let variations = node["variations"] as? [String: Any] {
                for (kind, cases) in variations {
                    for (name, sub) in cases as? [String: Any] ?? [:] {
                        if let sub = sub as? [String: Any] { walk(sub, "\(kind).\(name)") }
                    }
                }
            }
            if let substitutions = node["substitutions"] as? [String: Any] {
                for (name, sub) in substitutions { if let sub = sub as? [String: Any] { walk(sub, "sub.\(name)") } }
            }
        }
        walk(en, "")
        return out
    }
}

enum FormatSpecifiers {
    /// Position → length+conversion (`@`, `lld`, `f`…). `%%` is a literal; `%#@name@` substitutions
    /// are recorded under their name's conversion `@`.
    static func parse(_ text: String) -> [Int: String] {
        let spec = /%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])/
        var result: [Int: String] = [:]
        var next = 1
        for match in text.matches(of: spec) where match.3 != "%" {
            let position = match.1.flatMap { Int($0) } ?? next
            if match.1 == nil { next += 1 }
            result[position] = String(match.2 ?? "") + String(match.3)
        }
        return result
    }
}

enum SourceScan {
    struct Usage { let file: String; let line: Int; let key: String }

    /// Literal keys looked up in PincerUI's bundle: `Text("Send", bundle: .module)`,
    /// `String(localized: "Send", bundle: .module, comment: …)`, and PincerUI's helpers
    /// `L("Send")` / `Text(l: "Send")`. Matches inside `//` comments are ignored.
    static func moduleBundleKeys(in folder: URL) throws -> [Usage] {
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        return try files.flatMap { try keys(in: String(contentsOf: $0, encoding: .utf8), file: $0.lastPathComponent) }
    }

    static func keys(in text: String, file: String) throws -> [Usage] {
        let chars = Array(text)
        let before = [try Regex(#"(?:^|[^A-Za-z0-9_.])L\(\s*$"#), try Regex(#"Text\(\s*l\s*:\s*$"#)]
        let after = try Regex(#"^\s*,\s*(?:(?:table|tableName)\s*:\s*[^,()]+,\s*)?bundle\s*:\s*\.module"#)
        let tableArgument = try Regex(#"(?:table|tableName)\s*:\s*$"#)
        var usages: [Usage] = []
        for literal in StringLiterals.scan(chars) {
            let prefix = String(chars[max(0, literal.start - 40)..<literal.start])
            let suffix = String(chars[literal.end..<min(chars.count, literal.end + 80)])
            if prefix.firstMatch(of: tableArgument) != nil { continue }
            guard before.contains(where: { prefix.firstMatch(of: $0) != nil }) || suffix.prefixMatch(of: after) != nil else { continue }
            let line = chars[..<literal.start].count(where: { $0 == "\n" }) + 1
            usages.append(Usage(file: file, line: line, key: unescape(literal.content)))
        }
        return usages
    }

    static func unescape(_ literal: String) -> String {
        literal.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\\"#, with: "\\")
    }

    /// For a key with `\(…)` interpolations, a regex matching the catalog key Swift generates
    /// (each interpolation becomes a format specifier such as `%@` or `%lld`).
    static func interpolationPattern(_ key: String) -> Regex<AnyRegexOutput>? {
        guard key.contains("\\(") else { return nil }
        var pattern = ""
        var index = key.startIndex
        while index < key.endIndex {
            if key[index...].hasPrefix("\\("), let close = matchingParen(in: key, from: key.index(index, offsetBy: 2)) {
                pattern += #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA]"#
                index = key.index(after: close)
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(key[index]))
                index = key.index(after: index)
            }
        }
        return try? Regex(pattern)
    }

    private static func matchingParen(in text: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" { depth -= 1; if depth == 0 { return index } }
            index = text.index(after: index)
        }
        return nil
    }
}

/// Single-line Swift string literals in source, including ones nested in `\\(…)` interpolations.
/// Skips comments, raw strings and multi-line literals (never catalog keys here).
enum StringLiterals {
    struct Literal { let start: Int; let end: Int; let content: String }

    static func scan(_ c: [Character]) -> [Literal] {
        var found: [Literal] = []
        var i = 0
        func at(_ j: Int, _ s: String) -> Bool {
            let s = Array(s)
            return j + s.count <= c.count && Array(c[j..<j + s.count]) == s
        }
        func skip(to terminator: String, from j: Int) -> Int {
            var j = j
            while j < c.count, !at(j, terminator) { j += 1 }
            return min(c.count, j + terminator.count)
        }
        /// Parses a `"…"` literal starting at `j`, recording nested ones first; returns the index after it.
        func literal(_ j: Int) -> Int {
            var k = j + 1
            while k < c.count {
                if c[k] == "\\", k + 1 < c.count, c[k + 1] == "(" {
                    k += 2
                    var depth = 1
                    while k < c.count, depth > 0 {
                        if c[k] == "\"" { k = literal(k); continue }
                        if c[k] == "(" { depth += 1 }
                        if c[k] == ")" { depth -= 1 }
                        k += 1
                    }
                } else if c[k] == "\\" {
                    k += 2
                } else if c[k] == "\"" {
                    found.append(Literal(start: j, end: k + 1, content: String(c[(j + 1)..<k])))
                    return k + 1
                } else if c[k] == "\n" {
                    return k
                } else {
                    k += 1
                }
            }
            return k
        }
        while i < c.count {
            if at(i, "//") { i = skip(to: "\n", from: i) }
            else if at(i, "/*") { i = skip(to: "*/", from: i + 2) }
            else if c[i] == "#" {
                var hashes = 0
                while i + hashes < c.count, c[i + hashes] == "#" { hashes += 1 }
                guard at(i + hashes, "\"") else { i += hashes; continue }
                let multi = at(i + hashes, "\"\"\"")
                let close = (multi ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
                i = skip(to: close, from: i + hashes + (multi ? 3 : 1))
            } else if at(i, "\"\"\"") { i = skip(to: "\"\"\"", from: i + 3) }
            else if c[i] == "\"" { i = literal(i) }
            else { i += 1 }
        }
        return found
    }
}

/// Minimal JSON walker that reports duplicate object keys (which `JSONSerialization` silently drops).
enum StrictJSON {
    struct Invalid: Error { let offset: Int }

    static func duplicateKeys(in data: Data) throws -> [String] {
        var parser = Parser(bytes: Array(data))
        try parser.value(path: "")
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw Invalid(offset: parser.index) }
        return parser.duplicates
    }

    struct Parser {
        let bytes: [UInt8]
        var index = 0
        var duplicates: [String] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            skipSpace()
            guard index < bytes.count, bytes[index] == byte else { throw Invalid(offset: index) }
            index += 1
        }

        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            let start = index
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw Invalid(offset: index) }
            let raw = Data([UInt8(ascii: "\"")] + bytes[start..<index] + [UInt8(ascii: "\"")])
            index += 1
            return (try? JSONDecoder().decode(String.self, from: raw)) ?? String(decoding: bytes[start..<index - 1], as: UTF8.self)
        }

        mutating func value(path: String) throws {
            skipSpace()
            guard index < bytes.count else { throw Invalid(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var seen: Set<String> = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return }
                while true {
                    let key = try string()
                    let child = path.isEmpty ? key : "\(path).\(key)"
                    if !seen.insert(key).inserted { duplicates.append(child) }
                    try expect(UInt8(ascii: ":"))
                    try value(path: child)
                    skipSpace()
                    guard index < bytes.count else { throw Invalid(offset: index) }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return
                }
            case UInt8(ascii: "["):
                index += 1
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return }
                var element = 0
                while true {
                    try value(path: "\(path)[\(element)]")
                    element += 1
                    skipSpace()
                    guard index < bytes.count else { throw Invalid(offset: index) }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return
                }
            case UInt8(ascii: "\""):
                _ = try string()
            default:
                let start = index
                while index < bytes.count, !Set(",]} \n\r\t".utf8).contains(bytes[index]) { index += 1 }
                guard index > start else { throw Invalid(offset: index) }
            }
        }
    }
}
