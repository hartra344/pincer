import Foundation
import PincerKit

// The "Check the MCP servers" chat (issue #324): upstream-shaped exec, failed exec, edit, bundle-MCP,
// web_fetch and read calls, from the built-in demo and from the mock Gateway.

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
    let loaded = await waitFor("\(label) tool-cards history") { cardTools(chat).count >= 11 }
    let calls = cardTools(chat)
    check(loaded && calls.map(\.name) == ["exec", "exec", "read", "edit", "github__search_issues", "web_fetch", "linear__create_issue", "linear__list_teams",
                           "linear__update_issue", "mcp__filesystem__read_file", "acme-docs__search"],
          "\(label): tool calls in order (\(calls.map(\.name)))")
    guard calls.count >= 11 else { return }
    check(calls.map(\.isError) == [false, true, false, false, false, false, false, false, true, false, false] && calls.allSatisfy { !$0.isRunning },
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
    checkToolCardPresentations(calls, label: label)
}

@MainActor
private func checkToolCardPresentations(_ calls: [ToolActivity], label: String) {
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
    let fetch = ToolCallPresentation.make(calls[5])
    check(fetch.kind == .webFetch && fetch.output?.status == "200", "\(label): web_fetch status is 200 (\(fetch.output?.status ?? "nil"))")

    // A live run stores the whole result envelope; the card still shows just the text.
    var live = calls[0]
    live.result = """
    {"content":[{"type":"text","text":"line one\\nline two"}],"details":{"status":"completed","exitCode":0,"durationMs":900,"aggregated":"line one\\nline two"}}
    """
    let unwrapped = ToolCallPresentation.make(live).output
    check(unwrapped?.text == "line one\nline two" && unwrapped?.exitCode == 0, "\(label): envelope result is unwrapped (\(unwrapped?.text ?? "nil"))")
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
