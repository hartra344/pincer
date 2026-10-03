import Foundation
import PincerKit

// The "Check the MCP servers" chat (issue #324): upstream-shaped exec, failed exec, edit, bundle-MCP,
// web_fetch, web_search and read calls, from the built-in demo and from the mock Gateway.

private let toolCardsKey = "agent:main:dashboard:tool-cards"

@MainActor
private func cardTools(_ chat: ChatStore) -> [ToolActivity] {
    chat.entries.flatMap { entry -> [ToolActivity] in
        if case let .assistant(turn) = entry { return turn.tools }
        return []
    }
}

@MainActor
private func checkToolCardsChat(_ gateway: GatewayStore, label: String) async {
    check(gateway.sessions[toolCardsKey] != nil, "\(label): has the Check the MCP servers chat")
    let chat = gateway.chat(for: toolCardsKey)
    await chat.load()
    let loaded = await waitFor("\(label) tool-cards history") { cardTools(chat).count >= 13 }
    let calls = cardTools(chat)
    check(loaded && calls.map(\.name) == ["exec", "exec", "read", "edit", "github__search_issues", "web_fetch", "linear__create_issue", "linear__list_teams",
                           "linear__update_issue", "mcp__filesystem__read_file", "acme-docs__search", "web_search", "read"],
          "\(label): tool calls in order (\(calls.map(\.name)))")
    guard calls.count >= 13 else { return }
    check(calls.map(\.isError) == [false, true, false, false, false, false, false, false, true, false, false, false, false] && calls.allSatisfy { !$0.isRunning },
          "\(label): only the second exec failed (\(calls.map(\.isError)))")
    check(calls[0].arguments?.contains("openclaw mcp status --verbose") == true
          && calls[0].arguments?.contains("workdir") == true, "\(label): exec arguments carry command and workdir")
    let output = calls[0].result ?? ""
    check(output.contains("- Era") && output.contains("authorization required (OAuth pending)")
          && output.split(separator: "\n", omittingEmptySubsequences: false).count >= 20,
          "\(label): exec output is multi-line and shows the OAuth-pending server")
    check(calls[0].details?["exitCode"]?.double == 0 && calls[0].details?["durationMs"]?.double == 1240
          && calls[1].details?["exitCode"]?.double == 1 && calls[5].details?["status"]?.double == 200,
          "\(label): loaded history keeps exit code, duration and HTTP status in details")
    check(calls[1].result?.contains("openclaw mcp auth Era") == true, "\(label): failed exec has stderr-like text")
    check(calls[3].fileEdit?.primaryPath == "src/mcp/servers.json" && calls[3].fileEdit?.additions == 1
          && calls[3].fileEdit?.deletions == 1, "\(label): edit is a one-line diff of servers.json")
    check(calls[4].arguments?.contains("\"query\"") == true && calls[4].arguments?.contains("hartra344/pincer") == true && calls[4].result?.contains("\"number\": 324") == true,
          "\(label): MCP call has query args and a JSON list result")
    check(calls[5].arguments?.contains("\"extractMode\"") == true && calls[5].result?.hasPrefix("# Connecting MCP servers") == true,
          "\(label): web_fetch has its url args and markdown text")
    check(calls[2].arguments?.contains("\"offset\"") == true && calls[2].result?.contains("\"servers\"") == true,
          "\(label): read has path, offset, limit and the file text")
    let contextMenuMCP = calls.first { $0.name == "mcp__filesystem__read_file" }
    check(contextMenuMCP.map { MCPToolName.split($0.name).server == "filesystem" } == true,
          "\(label): seeded MCP tool card retains the exact raw name and server for its native context actions")
    checkToolCardPresentations(calls, label: label)
}

@MainActor
private func checkToolCardPresentations(_ calls: [ToolActivity], label: String) {
    checkToolSyntaxContrast(calls, label: label)
    let exec = ToolCallPresentation.make(calls[0])
    let text = exec.output?.text ?? ""
    check(exec.kind == .exec && exec.headline == "openclaw mcp status --verbose 2>&1 | grep -A4 \"^- Era\"",
          "\(label): exec headline is the command, unescaped (\(exec.headline ?? "nil"))")
    check(text.contains("\n") && !text.contains("\\n") && !text.contains("\"content\"") && !text.contains("\"details\"")
          && text.components(separatedBy: "MCP servers (4 configured)").count == 2,
          "\(label): exec output has real newlines, no envelope or escapes, and isn't repeated")
    check(exec.output?.exitCode == 0 && exec.output?.durationMs == 1240 && exec.output?.isError == false,
          "\(label): exec exit 0 in 1240 ms (\(exec.output?.exitCode ?? -1), \(exec.output?.durationMs ?? -1))")
    let failed = ToolCallPresentation.make(calls[1])
    check(failed.output?.exitCode == 1 && failed.output?.isError == true, "\(label): failed exec has exit code 1 and the error flag")
    let mcp = ToolCallPresentation.make(calls[4])
    check(mcp.kind == .mcp && mcp.mcpServer == "github" && mcp.displayName == "search_issues",
          "\(label): MCP call is github · search_issues (\(mcp.mcpServer ?? "nil") \(mcp.displayName))")
    for (name, server, tool) in [("mcp__github__search_issues", "github", "search_issues"), ("home-assistant__turn_on", "home-assistant", "turn_on"),
                                 ("fs__read__file", "fs", "read__file")]
    {
        var call = calls[4]
        call.name = name
        let p = ToolCallPresentation.make(call)
        check(p.kind == .mcp && p.mcpServer == server && p.displayName == tool, "\(label): \(name) splits to \(server) · \(tool) (\(p.mcpServer ?? "nil") \(p.displayName))")
    }
    let expected: [(Int, String, String)] = [(6, "linear", "create_issue"), (7, "linear", "list_teams"), (8, "linear", "update_issue"),
                                             (9, "filesystem", "read_file"), (10, "acme-docs", "search")]
    for (index, server, tool) in expected {
        let p = ToolCallPresentation.make(calls[index])
        let header = MCPToolName.split(calls[index].name)
        check(p.kind == .mcp && p.mcpServer == server && p.displayName == tool && header.server == server && header.tool == tool,
              "\(label): \(calls[index].name) is \(server) · \(tool) (\(p.mcpServer ?? "nil") \(p.displayName))")
    }
    check(calls[6].arguments?.contains("PIN") == true && calls[6].result?.isEmpty == false, "\(label): create_issue has arguments and a result")
    check(ToolCallPresentation.make(calls[7]).arguments.isEmpty && calls[7].result?.isEmpty == false, "\(label): list_teams has empty arguments and a result")
    check(ToolCallPresentation.make(calls[8]).output?.isError == true, "\(label): update_issue shows an error")
    check(MCPToolName.safeServerName("acme.docs") == "acme-docs", "acme.docs is acme-docs in transcripts")
    let configured = ["acme.docs", "filesystem", "linear"]
    let resolved = configured.first { $0 == "acme-docs" } ?? configured.first { MCPToolName.safeServerName($0) == "acme-docs" }
    check(resolved == "acme.docs", "\(label): acme-docs resolves to config acme.docs (\(resolved ?? "nil"))")
    checkWebSearchCard(calls[11], label: label)
    let swiftRead = ToolCallPresentation.make(calls[12])
    let swiftText = swiftRead.output?.text ?? ""
    check(swiftRead.kind == .read && swiftRead.headline?.hasSuffix(".swift") == true
          && ToolSyntax.language(forPath: swiftRead.headline ?? "") == .swift
          && ToolSyntax.tokens(in: swiftText, language: .swift).contains { $0.kind == .keyword }
          && ToolSyntax.tokens(in: swiftText, language: .swift).contains { $0.kind == .comment },
          "\(label): read of a .swift file tokenizes keywords and comments")
    let issues = ToolCallPresentation.make(calls[4]).output?.text ?? ""
    check(ToolSyntax.looksLikeJSON(issues) && ToolSyntax.tokens(in: issues, language: .json).contains { $0.kind == .key },
          "\(label): MCP JSON result tokenizes as JSON")
    check(calls.prefix(2).allSatisfy { $0.durationMs != nil } && calls[0].durationMs == 1240 && calls[5].durationMs == 412
          && calls[11].durationMs == 640 && calls[4].durationMs == nil,
          "\(label): header duration derives from durationMs / tookMs (\(calls.map { $0.durationMs ?? -1 }))")
    let fetch = ToolCallPresentation.make(calls[5])
    check(fetch.kind == .webFetch && fetch.output?.status == "200", "\(label): web_fetch status is 200 (\(fetch.output?.status ?? "nil"))")
    if label == "demo" {
        let seededFetch = calls[5]
        let reconstructedFetch = ToolActivity(
            id: seededFetch.id, name: seededFetch.name, arguments: seededFetch.arguments,
            result: seededFetch.result, details: seededFetch.details,
            isError: seededFetch.isError, isRunning: seededFetch.isRunning
        )
        let copiedFetch = seededFetch
        check(seededFetch.presentationCacheRevision != reconstructedFetch.presentationCacheRevision
              && copiedFetch.presentationCacheRevision == seededFetch.presentationCacheRevision
              && seededFetch == reconstructedFetch
              && seededFetch.hashValue == reconstructedFetch.hashValue
              && Set([seededFetch, reconstructedFetch]).count == 1,
              "demo: reconstructed web_fetch snapshots retain semantic identity while copies keep the presentation revision")

        var updatedFetch = reconstructedFetch
        updatedFetch.details = ["status": 503]
        let updatedPresentation = ToolCallPresentation.make(updatedFetch)
        check(updatedFetch.presentationCacheRevision != reconstructedFetch.presentationCacheRevision
              && updatedFetch != reconstructedFetch
              && updatedPresentation.output?.status == "503",
              "demo: changing seeded web_fetch details rotates presentation identity and updates its status")
    }

    // A live run stores the whole result envelope; the card still shows just the text.
    var live = calls[0]
    live.result = """
    {"content":[{"type":"text","text":"line one\\nline two"}],"details":{"status":"completed","exitCode":0,"durationMs":900,"aggregated":"line one\\nline two"}}
    """
    let unwrapped = ToolCallPresentation.make(live).output
    check(unwrapped?.text == "line one\nline two" && unwrapped?.exitCode == 0, "\(label): envelope result is unwrapped (\(unwrapped?.text ?? "nil"))")
}

@MainActor
private func checkToolSyntaxContrast(_ calls: [ToolActivity], label: String) {
    let defaultPairs: [(UInt32, UInt32)] = [
        (0x0550AE, 0xFFFFFF), (0x953800, 0xFFFFFF), (0x116329, 0xFFFFFF),
        (0x6639BA, 0xFFFFFF), (0x57606A, 0xFFFFFF),
        (0x79C0FF, 0x1C1C1E), (0xFFA657, 0x1C1C1E), (0x7EE787, 0x1C1C1E),
        (0xD2A8FF, 0x1C1C1E), (0x8B949E, 0x1C1C1E),
    ]
    check(defaultPairs.allSatisfy { foreground, background in
        ToolSyntaxContrast.ratio(foreground: foreground, background: background) >= 4.5
            && ToolSyntaxContrast.foreground(foreground, on: background) == foreground
    }, "\(label): established light/dark tool syntax shades stay unchanged when readable")

    let custom: UInt32 = 0x0550AE
    let repaired = ToolSyntaxContrast.foreground(custom, on: custom)
    check(repaired != custom && ToolSyntaxContrast.ratio(foreground: repaired, background: custom) >= 4.5,
          "\(label): a custom code background repairs a matching syntax shade")

    let high = ToolSyntaxContrast.foreground(0x0550AE, on: 0x333333, increased: true)
    check(ToolSyntaxContrast.ratio(foreground: high, background: 0x333333) >= 7,
          "\(label): increased contrast reaches 7:1 on a surface where it is achievable")
    let mid: UInt32 = 0x777777
    let best = max(ToolSyntaxContrast.ratio(foreground: 0, background: mid),
                   ToolSyntaxContrast.ratio(foreground: 0xFFFFFF, background: mid))
    let fallback = ToolSyntaxContrast.foreground(0x888888, on: mid, increased: true)
    check(best < 7 && ToolSyntaxContrast.ratio(foreground: fallback, background: mid) == best,
          "\(label): impossible 7:1 requests use the best achievable endpoint")

    let seededOutput = ToolCallPresentation.make(calls[4]).output?.text ?? ""
    let seededTokens = ToolSyntax.jsonTokens(in: seededOutput)
    let seededKey = seededTokens.first { $0.kind == .key }
    let seededKeyShade = ToolSyntaxContrast.foreground(0x0550AE, on: 0x0550AE)
    check(!seededOutput.isEmpty && !seededTokens.isEmpty && seededKey != nil
          && seededOutput.contains("\"number\"") && seededOutput.contains("\"title\"")
          && seededKeyShade != 0x0550AE
          && ToolSyntaxContrast.ratio(foreground: seededKeyShade, background: 0x0550AE) >= 4.5,
          "\(label): seeded JSON output keeps its source and repairs the key-token shade against a matching code surface")
}

@MainActor
private func checkWebSearchCard(_ call: ToolActivity, label: String) {
    let p = ToolCallPresentation.make(call)
    guard let web = p.web else {
        check(false, "\(label): web_search has a link list (details: \(call.details.map { "\($0)" } ?? "nil"))")
        return
    }
    check(p.kind == .webSearch && web.kind == .results && web.provider == "brave" && web.results.count == 5 && web.isListable,
          "\(label): web_search lists 5 brave results (\(web.results.count))")
    check(web.results.allSatisfy { ["http", "https"].contains($0.url.scheme ?? "") && !$0.title.contains("<<<")
        && !($0.snippet ?? "").contains("<<<") && !($0.siteName ?? "").contains("<<<") },
          "\(label): web_search titles, snippets and sites are unwrapped http(s) links")
    check(web.results.contains { $0.snippet == nil } && web.results.contains { $0.published != nil } && web.results.contains { $0.siteName != nil },
          "\(label): web_search rows vary: no snippet, dated, site name")
    if label == "demo" {
        check(web.truncated && call.result?.contains("\"truncated\": true") == true,
              "demo: the Gateway-shaped result preserves its explicit truncation flag")
        if let snippet = web.results.first?.snippet {
            check(snippet.count == 181 && snippet.hasSuffix("…")
                  && p.searchTexts.contains(where: { $0.hasSuffix(snippet) })
                  && web.copyText == web.results.map { "\($0.title)\n\($0.url.absoluteString)" }.joined(separator: "\n"),
                  "demo: the long snippet stays available to Find while result Copy remains title/URL only")
        } else {
            check(false, "demo: the long first web-search result keeps its capped snippet")
        }
        let linkActions = AccessibilityText.linkActionsWithWebHosts(web.results.map {
            .init(text: $0.title, url: $0.url, webHost: $0.url.host(percentEncoded: false))
        })
        check(linkActions.count == web.results.count
              && linkActions.first?.title == web.results[0].title
              && linkActions.first?.webHost == web.results[0].url.host(percentEncoded: false),
              "demo: parsed web-search link actions preserve the result title and owning host")
        check(linkActions.allSatisfy { $0.webHost != nil && !($0.title ?? "").contains("https://") },
              "demo: web-search link actions expose host context without using the full URL as a title")
    }
    check(Array(p.searchTexts.suffix(web.results.count)) == web.results.map(\.text) && !p.searchTexts.contains { $0.contains("\"kind\"") },
          "\(label): web_search Find strings are the drawn rows")
    check(p.output?.durationMs == 640 && call.result?.contains("<<<EXTERNAL_UNTRUSTED_CONTENT") == true,
          "\(label): web_search keeps tookMs and the upstream envelope in the raw result")
    check(web.copyText.split(separator: "\n").count == web.results.count * 2, "\(label): web_search Copy is title/url lines")
}

@MainActor
func runDemoToolCards() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for tool cards", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for tool cards connected")
    guard connected else { return }
    defer { gateway.stop() }
    await checkToolCardsChat(gateway, label: "demo")
}

@MainActor
func runLiveToolCards(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock tool cards", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("mock for tool cards", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "mock for tool cards connected")
    guard connected else { return }
    defer { gateway.stop() }
    await checkToolCardsChat(gateway, label: "mock")
}
