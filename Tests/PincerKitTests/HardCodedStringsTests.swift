import Foundation
import Testing

/// Ratchet for #192: user-facing literals in PincerUI must go through the String Catalog
/// (`L("…")` / `Text("…", bundle: .module)`). Literals already in the tree are listed in `baseline`
/// as `"File.swift|literal": occurrences`; new ones fail, and entries that vanish must be removed.
@Suite("Hard-coded strings")
struct HardCodedStringsTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let baseline: [String: Int] = [
        #"AttachmentIngest.swift|Remove \(self.attachment.fileName)"#: 1,
        #"AutomationsView.swift|This automation runs a \(self.draft.original?.payloadKind ?? "custom") task, which can only be changed in the Control UI or the config."#: 1,
        #"AutomationsView.swift|\(model.jobs.count) automation\(model.jobs.count == 1 ? "" : "s"). The next one runs \(next.formatted(.relative(presentation: .named)))."#: 1,
        #"ChatView.swift|\(self.gateway.agent(approval.agentId ?? "main").name) wants to run a command"#: 1,
        #"ContextMeter.swift|In \(row.inputTokens.map(TokenCount.format) ?? "–")"#: 1,
        #"ContextMeter.swift|Out \(row.outputTokens.map(TokenCount.format) ?? "–")"#: 1,
        #"ExecPolicyPage.swift|The Gateway has no policy file yet and uses its defaults. Saving creates \(snapshot.path ?? "the policy file")."#: 1,
        #"GatewayHealthPage.swift|\(beat.status.label) · \(Text(at, style: .relative)) ago"#: 1,
        #"GatewayLogsPage.swift|\(level.label) (\(model.count(level).formatted()))"#: 1,
        #"MenuBarExtra.swift|Add Gateway…"#: 1,
        #"MenuBarExtra.swift|Set Up Gateway…"#: 1,
        #"NotificationSettingsSection.swift|Background App Refresh is off for Pincer"#: 1,
        #"NotificationSettingsSection.swift|Background App Refresh is restricted on this device"#: 1,
        #"NotificationSettingsSection.swift|Not yet"#: 1,
        #"NotificationSettingsSection.swift|Notifications"#: 1,
        #"NotificationSettingsSection.swift|Notify about replies and approvals"#: 1,
        #"NotificationSettingsSection.swift|Open Settings"#: 1,
        #"NotificationSettingsSection.swift|Push relay"#: 1,
        #"NotificationSettingsSection.swift|While Pincer is closed"#: 1,
        #"NotificationSettingsSection.swift|https://relay.example.com"#: 1,
        #"SessionManagerViews.swift|Actions"#: 1,
        #"SessionManagerViews.swift|Archive"#: 2,
        #"SessionManagerViews.swift|Archived"#: 1,
        #"SessionManagerViews.swift|Branches"#: 1,
        #"SessionManagerViews.swift|Cancel"#: 4,
        #"SessionManagerViews.swift|Connect to the Gateway to manage sessions."#: 1,
        #"SessionManagerViews.swift|Copy Session Key"#: 1,
        #"SessionManagerViews.swift|Couldn't Load Sessions"#: 1,
        #"SessionManagerViews.swift|Delete"#: 2,
        #"SessionManagerViews.swift|Delete…"#: 3,
        #"SessionManagerViews.swift|Details"#: 1,
        #"SessionManagerViews.swift|Details…"#: 1,
        #"SessionManagerViews.swift|Filter sessions"#: 1,
        #"SessionManagerViews.swift|Interrupted"#: 1,
        #"SessionManagerViews.swift|Interrupted by a Gateway restart"#: 2,
        #"SessionManagerViews.swift|No branches"#: 1,
        #"SessionManagerViews.swift|No messages to rewind to"#: 1,
        #"SessionManagerViews.swift|Preview"#: 1,
        #"SessionManagerViews.swift|Previews need a newer Gateway."#: 1,
        #"SessionManagerViews.swift|Recover Session"#: 1,
        #"SessionManagerViews.swift|Refresh"#: 2,
        #"SessionManagerViews.swift|Rewind"#: 2,
        #"SessionManagerViews.swift|Rewind…"#: 1,
        #"SessionManagerViews.swift|Sessions"#: 1,
        #"SessionManagerViews.swift|Show"#: 1,
        #"SessionManagerViews.swift|Show Details"#: 1,
        #"SessionManagerViews.swift|Switch Branch"#: 1,
        #"SessionManagerViews.swift|Switch…"#: 1,
        #"SessionManagerViews.swift|The rewound message is back in the composer."#: 1,
        #"SessionManagerViews.swift|Try Again"#: 1,
        #"SessionManagerViews.swift|Unarchive"#: 2,
        #"SessionManagerViews.swift|Unarchive the session to rewind it."#: 1,
        #"SessionManagerViews.swift|Wait for the current run to finish to rewind."#: 1,
        #"SessionManagerViews.swift|\(self.selection.count) selected"#: 1,
        #"SettingsPages.swift|Remove \(field?.label ?? "Entry")"#: 1,
    ]

    @Test func noNewHardCodedUserFacingStrings() throws {
        let folder = Self.root.appending(path: "Sources/PincerUI")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var found: [String: [HardCodedStrings.Hit]] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for hit in try HardCodedStrings.scan(text, file: file.lastPathComponent) {
                found["\(hit.file)|\(hit.literal)", default: []].append(hit)
            }
        }
        var problems: [String] = []
        for (key, hits) in found.sorted(by: { $0.key < $1.key }) where hits.count > (Self.baseline[key] ?? 0) {
            for hit in hits.dropFirst(Self.baseline[key] ?? 0) {
                problems.append("\(hit.file):\(hit.line) \"\(hit.literal)\"")
            }
        }
        #expect(problems.isEmpty, """
        New hard-coded user-facing strings in PincerUI. Use L("…") or Text("…", bundle: .module), \
        then run scripts/sync-strings.sh:
        \(problems.joined(separator: "\n"))
        """)
        let stale = Self.baseline.filter { (found[$0.key]?.count ?? 0) < $0.value }.keys.sorted()
        #expect(stale.isEmpty, """
        Baseline entries no longer occur (or occur less often); shrink `HardCodedStringsTests.baseline`:
        \(stale.joined(separator: "\n"))
        """)
    }

    @Test func matcherFlagsOnlyUncataloguedLiterals() throws {
        let source = """
        Text("Plain")
        Text("Keyed", bundle: .module)
        Text(verbatim: "Raw")
        Text("\\(count)")
        Text("12:30")
        Button("Save") {}
        Button(L("Save")) {}
        Label("Tags", systemImage: "tag")
        .help("Hover me")
        .accessibilityLabel(L("Fine"))
        .navigationTitle("Title")
        NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        UIAction(title: L("Copy")) { _ in }
        let other = "Not an API call"
        """
        let hits = try HardCodedStrings.scan(source, file: "X.swift").map(\.literal)
        #expect(hits == ["Plain", "Save", "Tags", "Hover me", "Title", "Copy"])
    }
}

enum HardCodedStrings {
    struct Hit { let file: String; let line: Int; let literal: String }

    static func scan(_ text: String, file: String) throws -> [Hit] {
        let chars = Array(text)
        let viewCalls = try Regex(#"(?:^|[^A-Za-z0-9_.])(?:Text|Button|Label|Toggle|Section|Picker|TextField|Menu)\(\s*$"#)
        let modifiers = try Regex(#"\.(?:help|accessibilityLabel|accessibilityHint|navigationTitle)\(\s*$"#)
        let titles = try Regex(#"(?:NSMenuItem|UIAction)\(\s*title:\s*$"#)
        let catalogued = try Regex(#"^\s*,\s*(?:(?:table|tableName)\s*:\s*[^,()]+,\s*)?bundle\s*:\s*\.module"#)
        let interpolation = try Regex(#"\\\([^)]*\)"#)
        var hits: [Hit] = []
        for literal in StringLiterals.scan(chars) {
            let prefix = String(chars[max(0, literal.start - 40)..<literal.start])
            let suffix = String(chars[literal.end..<min(chars.count, literal.end + 80)])
            let isTarget = prefix.firstMatch(of: viewCalls) != nil || prefix.firstMatch(of: modifiers) != nil
                || prefix.firstMatch(of: titles) != nil
            guard isTarget, suffix.prefixMatch(of: catalogued) == nil else { continue }
            guard literal.content.replacing(interpolation, with: "").contains(where: \.isLetter) else { continue }
            let line = chars[..<literal.start].count(where: { $0 == "\n" }) + 1
            hits.append(Hit(file: file, line: line, literal: SourceScan.unescape(literal.content)))
        }
        return hits
    }
}
