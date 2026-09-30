import Foundation
import Testing
@testable import PincerKit

@Suite("Tool call presentation")
struct ToolCallPresentationTests {
    private func tool(_ name: String, args: String? = nil, result: String? = nil, details: JSONValue? = nil,
                      isError: Bool = false) -> ToolActivity
    {
        ToolActivity(id: "t1", name: name, arguments: args, result: result, details: details,
                     isError: isError, isRunning: false)
    }

    private let screenshot = """
    {
      "content": [ { "type": "text", "text": "one\\ntwo\\nthree" } ],
      "details": { "aggregated": "one\\ntwo\\nthree" }
    }
    """

    @Test func unwrapsEnvelopeOnceWithRealNewlines() {
        let out = ToolCallPresentation.make(tool("exec", args: #"{"command":"ls"}"#, result: screenshot)).output
        #expect(out?.text == "one\ntwo\nthree")
        #expect(out?.lineCount == 3)
    }

    @Test func fallsBackToAggregatedWhenContentEmpty() {
        let r = #"{"content":[],"details":{"aggregated":"hello"}}"#
        #expect(ToolOutputText.unwrap(r).text == "hello")
    }

    @Test func countsImages() {
        let r = #"{"content":[{"type":"text","text":"a"},{"type":"image","data":"x"},{"type":"image"}]}"#
        let u = ToolOutputText.unwrap(r)
        #expect(u.text == "a")
        #expect(u.imageCount == 2)
    }

    @Test func plainTextIsVerbatim() {
        #expect(ToolOutputText.unwrap("hello  world\n").text == "hello  world\n")
    }

    @Test func nonEnvelopeJSONIsPrettyPrintedInOrder() {
        let text = ToolOutputText.unwrap(#"{"zeta":1,"alpha":[1,2]}"#).text
        #expect(text == "{\n  \"zeta\": 1,\n  \"alpha\": [\n    1,\n    2\n  ]\n}")
    }

    @Test func unescapesLiteralNewlinesOnlyWhenFlat() {
        #expect(ToolOutputText.unwrap("a\\nb").text == "a\nb")
        #expect(ToolOutputText.unwrap("a\\nb\nc").text == "a\\nb\nc")
    }

    @Test func stripsANSI() {
        #expect(ToolOutputText.stripANSI("\u{1B}[31mred\u{1B}[0m ok") == "red ok")
        #expect(ToolOutputText.stripANSI("\u{1B}]0;title\u{07}x") == "x")
        let t = ToolCallPresentation.make(tool("x", result: "\u{1B}[1mhi\u{1B}[0m  \n\n"))
        #expect(t.output?.text == "hi")
    }

    @Test func capsOutputButCountsFullLines() {
        let full = (1...50).map { "line\($0)" }.joined(separator: "\n")
        let out = ToolCallPresentation.make(tool("x", result: full), limit: 20).output
        #expect(out?.text == String(full.prefix(20)) + "\n…")
        #expect(out?.lineCount == 50)
    }

    @Test func middleTruncates() {
        let s = ToolOutputText.middleTruncated("abcdefghij", max: 5)
        #expect(s.count == 5)
        #expect(s.contains("…"))
        #expect(ToolOutputText.middleTruncated("abc", max: 5) == "abc")
    }

    @Test func execSummaryChipsAndExit() {
        let args = #"{"command":"echo \"hi\"\nls","title":"List","workdir":"/a","timeoutSeconds":30,"background":true,"pty":false}"#
        let result = #"{"content":[{"type":"text","text":"ok"}],"details":{"status":"completed","exitCode":0,"durationMs":1200,"cwd":"/b"}}"#
        let p = ToolCallPresentation.make(tool("exec", args: args, result: result))
        #expect(p.kind == .exec)
        #expect(p.headline == "echo \"hi\"\nls")
        #expect(p.chips.map(\.symbol) == ["folder", "timer", "moon.zzz"])
        #expect(p.chips[0].value == "/b")
        #expect(p.chips[1].value == "30s")
        #expect(p.arguments.isEmpty)
        #expect(p.output?.exitCode == 0)
        #expect(p.output?.durationMs == 1200)
        #expect(p.output?.status == nil)
    }

    @Test func legacyCmdAndTimeout() {
        let p = ToolCallPresentation.make(tool("bash", args: #"{"cmd":"ls","timeout":5}"#))
        #expect(p.kind == .exec)
        #expect(p.headline == "ls")
        #expect(p.chips == [.init(symbol: "timer", label: "Timeout", value: "5s")])
        #expect(p.output == nil)
    }

    @Test func failedExec() {
        let result = #"{"content":[{"type":"text","text":"boom"}],"details":{"exitCode":1,"timedOut":true}}"#
        let p = ToolCallPresentation.make(tool("exec", args: #"{"command":"x"}"#, result: result, isError: true))
        #expect(p.output?.exitCode == 1)
        #expect(p.output?.status == "timed out")
        #expect(p.output?.isError == true)
        let sig = #"{"content":[{"type":"text","text":"x"}],"details":{"exitCode":null,"exitSignal":"SIGTERM"}}"#
        let q = ToolCallPresentation.make(tool("exec", args: #"{"command":"x"}"#, result: sig))
        #expect(q.output?.status == "signal SIGTERM")
        #expect(q.output?.exitCode == nil)
    }

    @Test func webFetch() {
        let args = #"{"url":"https://a.b","extractMode":"markdown","maxChars":100}"#
        let result = #"{"content":[{"type":"text","text":"page"}],"details":{"status":200,"tookMs":340}}"#
        let p = ToolCallPresentation.make(tool("web_fetch", args: args, result: result))
        #expect(p.kind == .webFetch)
        #expect(p.headline == "https://a.b")
        #expect(p.chips.first?.value == "markdown")
        #expect(p.arguments == [.init(key: "maxChars", value: "100", isNested: false)])
        #expect(p.output?.status == "200")
        #expect(p.output?.durationMs == 340)
    }

    @Test func webSearch() {
        let p = ToolCallPresentation.make(tool("web_search", args: #"{"query":"swift","count":5,"freshness":"day"}"#))
        #expect(p.kind == .webSearch)
        #expect(p.headline == "swift")
        #expect(p.chips == [.init(symbol: "number", label: "Result count", value: "5")])
        #expect(p.arguments.map(\.key) == ["freshness"])
    }

    @Test func readShowsPath() {
        let p = ToolCallPresentation.make(tool("read", args: #"{"file_path":"/x.txt","offset":3}"#))
        #expect(p.kind == .read)
        #expect(p.headline == "/x.txt")
        #expect(p.arguments.map(\.key) == ["offset"])
    }

    @Test func mcpNameSplitting() {
        let a = ToolCallPresentation.make(tool("github__search_issues"))
        #expect(a.kind == .mcp)
        #expect(a.mcpServer == "github")
        #expect(a.displayName == "search_issues")
        #expect(a.chips.first?.value == "github")
        let b = ToolCallPresentation.make(tool("mcp__github__search_issues"))
        #expect(b.mcpServer == "github")
        #expect(b.displayName == "search_issues")
    }

    @Test func mcpToolNameSplitRule() {
        typealias Case = (name: String, server: String?, tool: String)
        let cases: [Case] = [
            ("github__search_issues", "github", "search_issues"),
            ("mcp__github__search_issues", "github", "search_issues"),
            ("home-assistant__turn_on", "home-assistant", "turn_on"),
            ("my.server_2__do-it", "my.server_2", "do-it"),
            ("mcp__my.server__a.b", "my.server", "a.b"),
            // The server ends at the first `__`, so tool names may contain `__`.
            ("fs__read__file", "fs", "read__file"),
            ("mcp__fs__read__file", "fs", "read__file"),
            ("mcp__mcp__x", "mcp", "x"),
            // No usable split.
            ("exec", nil, "exec"),
            ("web_fetch", nil, "web_fetch"),
            ("__tool", nil, "__tool"),
            ("server__", nil, "server__"),
            ("mcp__", nil, "mcp__"),
            ("", nil, ""),
        ]
        for c in cases {
            let split = MCPToolName.split(c.name)
            #expect(split.server == c.server, "server of \(c.name)")
            if c.server != nil { #expect(split.tool == c.tool, "tool of \(c.name)") }
        }
    }

    @Test func safeServerNameSanitizes() {
        #expect(MCPToolName.safeServerName("github") == "github")
        #expect(MCPToolName.safeServerName("my.server") == "my-server")
        #expect(MCPToolName.safeServerName("home-assistant_2") == "home-assistant_2")
        #expect(MCPToolName.safeServerName("a b/c") == "a-b-c")
        #expect(MCPToolName.safeServerName("1password") == "mcp-1password")
        #expect(MCPToolName.safeServerName(" x ") == "x")
        #expect(MCPToolName.safeServerName("") == "mcp" && MCPToolName.safeServerName("   ") == "mcp")
        #expect(MCPToolName.safeServerName("_a") == "mcp-_a")
        // The prefix counts toward the 30-character limit.
        #expect(MCPToolName.safeServerName("9" + String(repeating: "b", count: 40)) == "mcp-9" + String(repeating: "b", count: 25))
        #expect(MCPToolName.safeServerName("0abc") == "mcp-0abc")
        #expect(MCPToolName.safeServerName("-x") == "mcp--x")
        #expect(MCPToolName.safeServerName("émoji") == "mcp--moji")
        #expect(MCPToolName.safeServerName(String(repeating: "a", count: 40)).count == 30)
        // The sanitised fragment survives a split, so a card's server resolves back to its config name.
        let split = MCPToolName.split("\(MCPToolName.safeServerName("my.server"))__do_it")
        #expect(split.server == MCPToolName.safeServerName("my.server") && split.tool == "do_it")
        // Sanitised names never contain the separator's first `__` unless the config name does.
        #expect(!MCPToolName.safeServerName("a.b").contains("__"))
    }

    @Test func presentationAgreesWithSplit() {
        for name in ["github__search_issues", "mcp__github__search_issues", "fs__read__file", "mcp__a-b.c__x",
                     "__tool", "server__", "mcp__", "a__b__c__d"]
        {
            let split = MCPToolName.split(name)
            let p = ToolCallPresentation.make(tool(name))
            #expect(p.kind == .mcp, "\(name)")
            #expect(p.mcpServer == split.server, "server of \(name)")
            if split.server != nil { #expect(p.displayName == split.tool, "tool of \(name)") }
        }
        // Names without `__` are not MCP.
        #expect(ToolCallPresentation.make(tool("exec")).kind != .mcp)
        #expect(ToolCallPresentation.make(tool("web_search")).mcpServer == nil)
        #expect(ToolCallPresentation.make(tool("a_b")).kind != .mcp)
    }

    @Test func genericKeepsKeyOrderAndNested() {
        let args = #"{"zeta":"z","alpha":{"b":1,"a":[1,2]},"n":2.5,"flag":true,"m":"l1\nl2"}"#
        let p = ToolCallPresentation.make(tool("custom", args: args))
        #expect(p.kind == .generic)
        #expect(p.arguments.map(\.key) == ["zeta", "alpha", "n", "flag", "m"])
        #expect(p.arguments[1] == .init(key: "alpha", value: #"{"b":1,"a":[1,2]}"#, isNested: true))
        #expect(p.arguments[2].value == "2.5")
        #expect(p.arguments[3].value == "true")
        #expect(p.arguments[4].value == "l1\nl2")
        #expect(p.rawArguments == args)
    }

    @Test func searchTextsMatchDrawOrder() {
        let p = ToolCallPresentation.make(tool("web_fetch", args: #"{"url":"u","maxChars":9}"#, result: "body"))
        #expect(p.searchTexts == ["u", "maxChars\t9", "body"])
        #expect(p.argumentsText == "maxChars\t9")
        let t = tool("web_fetch", args: #"{"url":"u","maxChars":9}"#, result: "body")
        #expect(TranscriptSearch.toolTexts(t, limit: 100) == p.searchTexts)
    }

    private func execStatus(_ details: String) -> String? {
        let r = #"{"content":[{"type":"text","text":"x"}],"details":\#(details)}"#
        return ToolCallPresentation.make(tool("exec", args: #"{"command":"x"}"#, result: r)).output?.status
    }

    @Test func execStatusOmitsCompletedAndFailed() {
        #expect(execStatus(#"{"status":"completed","exitCode":0}"#) == nil)
        #expect(execStatus(#"{"status":"failed","exitCode":1}"#) == nil)
    }

    @Test func execStatusHumanizesStates() {
        #expect(execStatus(#"{"status":"running"}"#) == "running")
        #expect(execStatus(#"{"status":"approval-pending"}"#) == "approval pending")
        #expect(execStatus(#"{"status":"approval-unavailable"}"#) == "approval unavailable")
    }

    @Test func execStatusFromFailureKind() {
        #expect(execStatus(#"{"status":"failed","failureKind":"no-output-timeout"}"#) == "no output timeout")
        #expect(execStatus(#"{"status":"failed","failureKind":"overall-timeout"}"#) == "timed out")
        #expect(execStatus(#"{"status":"failed","failureKind":"shell-command-not-found"}"#) == "command not found")
        #expect(execStatus(#"{"failureKind":"overall-timeout","exitSignal":"SIGKILL"}"#) == "signal SIGKILL")
    }

    @Test func chipLabelsAreStableEnglishKeys() {
        let args = #"{"command":"x","workdir":"/a","timeoutSeconds":3,"background":true,"pty":true,"elevated":true}"#
        let p = ToolCallPresentation.make(tool("exec", args: args))
        #expect(p.chips.map(\.label) == ["Working directory", "Timeout", "Background", "Pseudo-terminal", "Elevated"])
        let w = ToolCallPresentation.make(tool("web_fetch", args: #"{"url":"u","extractMode":"text"}"#))
        #expect(w.chips.map(\.label) == ["Extract mode"])
        #expect(ToolCallPresentation.make(tool("a__b")).chips.map(\.label) == ["Server"])
    }
}
