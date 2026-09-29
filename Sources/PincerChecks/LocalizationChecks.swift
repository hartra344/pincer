import Foundation
import PincerKit

/// Issue #58: the String Catalog is valid and English-sourced, the package declares its default
/// localization, and the accessibility label builders speak every seeded demo row.
private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// `%@`, `%lld`, `%1$@`… by position, ignoring `%%`.
private func formatSpecifiers(_ text: String) -> [Int: String] {
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

@MainActor
func runLocalizationChecks() {
    print("Localization")
    let manifest = (try? String(contentsOf: repoRoot.appending(path: "Package.swift"), encoding: .utf8)) ?? ""
    check(manifest.contains(/defaultLocalization:\s*"en"/), "Package.swift declares defaultLocalization \"en\"")

    let url = repoRoot.appending(path: "Sources/PincerUI/Resources/Localizable.xcstrings")
    guard let data = try? Data(contentsOf: url),
          let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        check(false, "Localizable.xcstrings exists and is JSON (\(url.path(percentEncoded: false)))")
        return
    }
    check(catalog["sourceLanguage"] as? String == "en", "catalog sourceLanguage is en")
    check((catalog["version"] as? String)?.isEmpty == false, "catalog has a version")
    let strings = catalog["strings"] as? [String: Any] ?? [:]
    check(!strings.isEmpty, "catalog has strings (\(strings.count))")
    check(!strings.keys.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "no empty keys")

    var missing: [String] = []
    var mismatched: [String] = []
    for (key, value) in strings {
        let entry = value as? [String: Any] ?? [:]
        if entry["shouldTranslate"] as? Bool == false { continue }
        let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
        var units: [String] = []
        if let unit = en?["stringUnit"] as? [String: Any] { units.append(unit["value"] as? String ?? "") }
        for cases in (en?["variations"] as? [String: Any] ?? [:]).values {
            for sub in (cases as? [String: Any] ?? [:]).values {
                if let unit = (sub as? [String: Any])?["stringUnit"] as? [String: Any] { units.append(unit["value"] as? String ?? "") }
            }
        }
        if units.isEmpty || units.contains(where: \.isEmpty) { missing.append(key) }
        let expected = formatSpecifiers(key)
        let isPlural = en?["variations"] != nil
        for unit in units {
            let actual = formatSpecifiers(unit)
            let ok = isPlural ? actual.allSatisfy { expected[$0.key] == $0.value } : actual == expected
            if !ok { mismatched.append("\(key) → \(unit)") }
        }
    }
    check(missing.isEmpty, "every key has a non-empty en value (missing: \(missing.sorted().prefix(10)))")
    check(mismatched.isEmpty, "format specifiers match between key and en value (\(mismatched.sorted().prefix(10)))")

    // #228: PincerKit's sentences are keys in this catalog (no bundle registered here, so they read as English keys).
    let kitPhrases = [
        MessageSender.unknownAgentName, MessageSender.automationName, MessageSender.helperName,
        MessageSender(kind: .automation).marker(agents: [], receivingAgentId: nil),
        MessageSender(kind: .helper).marker(agents: [], receivingAgentId: nil),
        MessageSender(kind: .agent).marker(agents: [], receivingAgentId: nil),
        MessageSender(kind: .agent, agentId: "main").marker(agents: [], receivingAgentId: "main"),
        AccessibilityText.contextMeterLabel,
        AccessibilityText.findStatus(current: nil, total: 0),
        AccessibilityText.speaker(role: .user, author: nil),
    ]
    check(kitPhrases.allSatisfy { strings[$0] != nil }, "sender names and accessibility phrases are catalog keys (missing: \(kitPhrases.filter { strings[$0] == nil }))")
    let templates = ["from %@’s chat", "Result %lld of %lld", "Expand %@", "Collapse %@", "%lld unread", "%lld results", "%lld tool calls"]
    check(templates.allSatisfy { strings[$0] != nil }, "interpolated PincerKit phrases are catalog keys (missing: \(templates.filter { strings[$0] == nil }))")
}

/// Every seeded demo session and transcript row gets a spoken label from `AccessibilityText`.
@MainActor
func runDemoAccessibility() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for accessibility") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for accessibility connected")
    guard connected else { return }
    defer { gateway.stop() }

    let agentNames = Dictionary(gateway.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    var badSessions: [String] = []
    for row in gateway.sessions.values {
        let label = AccessibilityText.sessionRow(
            title: row.title, agentName: agentNames[row.agentId], isUnread: row.isUnread, isPinned: row.isPinned,
            isRunning: row.hasActiveRun, hasError: row.lastRunError != nil, isArchived: row.isArchived, preview: row.preview)
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty || label.contains("\n") || !label.hasPrefix(title.isEmpty ? "Untitled session" : title)
            || (row.isUnread && !label.contains("nread")) || (row.isPinned && !label.contains("Pinned"))
        {
            badSessions.append("\(row.key): \(label)")
        }
    }
    check(badSessions.isEmpty, "every demo session row has a label (\(gateway.sessions.count) rows; bad: \(badSessions))")
    check(gateway.sessions.values.contains { $0.isUnread } && gateway.sessions.values.contains { $0.isPinned },
          "demo seeds unread and pinned rows to label")

    var rows = 0
    var bad: [String] = []
    for key in ["agent:main:main", "agent:research:main", "agent:coder:main", "agent:research:dashboard:papers", "agent:main:dashboard:trip"] {
        let chat = gateway.chat(for: key)
        await chat.load()
        _ = await waitFor("\(key) history") { chat.hasLoaded }
        let author = agentNames[SessionKey.agentId(from: key) ?? "main"]
        for entry in chat.entries {
            let label: String
            switch entry {
            case let .user(item):
                label = AccessibilityText.messageRow(role: item.role, text: item.plainText, isPending: item.isPending, via: item.via)
                if !label.hasPrefix("You") { bad.append("\(key) \(entry.id): \(label)") }
            case let .assistant(turn):
                label = AccessibilityText.messageRow(
                    role: .assistant, author: author, text: turn.body, toolCount: turn.tools.count,
                    attachmentCount: turn.images.count + turn.files.count, isStreaming: turn.isStreaming, isError: turn.isError)
                if let author, !label.hasPrefix(author) { bad.append("\(key) \(entry.id): \(label)") }
                if !turn.body.isEmpty, label.contains("No text") { bad.append("\(key) \(entry.id): lost body: \(label)") }
            case let .marker(_, text):
                label = AccessibilityText.messageRow(role: .marker, text: text)
            }
            rows += 1
            if label.isEmpty || label.contains("\n") || label.count > AccessibilityText.defaultSummaryLimit + 120 {
                bad.append("\(key) \(entry.id): \(label.prefix(80)) (\(label.count) chars)")
            }
        }
        if let usage = ContextUsage(row: gateway.sessions[key]) {
            let value = AccessibilityText.contextMeterValue(usage)
            if !value.contains("percent used") { bad.append("\(key) context meter: \(value)") }
        }
    }
    check(rows > 10, "demo transcripts seeded rows to label (\(rows))")
    check(bad.isEmpty, "every demo transcript row has a clean spoken label (bad: \(bad.prefix(5)))")
}
