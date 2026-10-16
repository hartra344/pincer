import Foundation
import Testing
@testable import PincerKit

/// The page-preview card for `browser` tool calls (#976): parsing `details.browserTab`, keeping it
/// through `fileEditDetails`, and building it from history and live agent events.
@MainActor
@Suite("Browser page preview")
struct BrowserPagePreviewTests {
    static func tab(_ extra: String = "", target: String = #""target":"host""#, url: String = #""url":"https://example.com/docs/page?q=1""#,
                    title: String = #""title":"  Example Docs  ""#) -> JSONValue {
        let fields = [#""targetId":"T1""#, #""profile":"openclaw""#, target, url, title, extra].filter { !$0.isEmpty }
        return Fixtures.json("{\"browserTab\":{\(fields.joined(separator: ","))}}")
    }

    static func parse(_ details: JSONValue?, tool: String = "browser", isError: Bool = false) -> BrowserPagePreview? {
        BrowserPagePreview.parse(toolName: tool, details: details, isError: isError, toolCallId: "c1")
    }

    @Test func hostTargetParsesWithTrimmedTitle() throws {
        let page = try #require(Self.parse(Self.tab()))
        #expect(page.toolCallId == "c1")
        #expect(page.url.absoluteString == "https://example.com/docs/page?q=1")
        #expect(page.title == "Example Docs")
        #expect(page.tabKey == "host|openclaw|T1")
        #expect(page.host == "example.com")
        #expect(page.displayTitle == "Example Docs")
        #expect(page.displayURL == "example.com/docs/page?q=1")
    }

    @Test func nodeTargetKeyIncludesTheNode() throws {
        let page = try #require(Self.parse(Self.tab(#""node":"mac-mini""#, target: #""target":"node""#)))
        #expect(page.tabKey == "node|mac-mini|openclaw|T1")
    }

    @Test func nodeTargetWithoutANodeIsRejectedOrKeyed() {
        // Upstream always sends `node` for target "node"; without it there is no stable tab identity.
        let page = Self.parse(Self.tab(target: #""target":"node""#))
        #expect(page == nil || page?.tabKey.hasPrefix("node|") == true)
    }

    @Test func missingTabFieldsYieldNil() {
        #expect(Self.parse(Fixtures.json(#"{"browserTab":{"profile":"openclaw","target":"host","url":"https://a.com"}}"#)) == nil, "no targetId")
        #expect(Self.parse(Fixtures.json(#"{"browserTab":{"targetId":"T1","target":"host","url":"https://a.com"}}"#)) == nil, "no profile")
        #expect(Self.parse(Fixtures.json(#"{"browserTab":{"targetId":"T1","profile":"p","url":"https://a.com"}}"#)) == nil, "no target")
        #expect(Self.parse(Fixtures.json(#"{"browserTab":{"targetId":"T1","profile":"p","target":"host"}}"#)) == nil, "no url")
        #expect(Self.parse(Fixtures.json(#"{"browserTab":{"targetId":"T1","profile":"p","target":"elsewhere","url":"https://a.com"}}"#)) == nil, "bad target")
        #expect(Self.parse(Fixtures.json(#"{"other":1}"#)) == nil, "no browserTab")
        #expect(Self.parse(nil) == nil)
    }

    @Test func onlyHTTPAndHTTPSURLsAreAccepted() {
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "about:blank", "data:text/html,hi", "ftp://a.com/x", "chrome://settings", "not a url"] {
            #expect(Self.parse(Self.tab(url: "\"url\":\"\(bad)\"")) == nil, "\(bad)")
        }
        #expect(Self.parse(Self.tab(url: #""url":"http://a.com/""#)) != nil)
    }

    @Test func errorsAndOtherToolsAreNotCards() {
        #expect(Self.parse(Self.tab(), isError: true) == nil)
        #expect(Self.parse(Self.tab(), tool: "web_fetch") == nil)
        #expect(Self.parse(Self.tab(), tool: "exec") == nil)
    }

    @Test func titleIsTrimmedAndEmptyIsNil() throws {
        let blank = try #require(Self.parse(Self.tab(title: #""title":"   \n ""#)))
        #expect(blank.title == nil)
        #expect(blank.displayTitle == "example.com")
        let none = try #require(Self.parse(Self.tab(title: "")))
        #expect(none.title == nil && none.displayTitle == "example.com")
    }

    @Test func displayURLDropsSchemeAndRootSlash() throws {
        let root = try #require(Self.parse(Self.tab(url: #""url":"https://example.com/""#)))
        #expect(root.displayURL == "example.com")
        let bare = try #require(Self.parse(Self.tab(url: #""url":"https://example.com""#)))
        #expect(bare.displayURL == "example.com")
        let query = try #require(Self.parse(Self.tab(url: #""url":"http://example.com/a/b?x=y&z=1#frag""#)))
        #expect(query.displayURL == "example.com/a/b?x=y&z=1")
        #expect(query.host == "example.com")
    }

    @Test func fileEditDetailsKeepsATrimmedBrowserTab() throws {
        let long = String(repeating: "t", count: 600)
        let longURL = "https://example.com/" + String(repeating: "u", count: 2100)
        let details = Fixtures.json("""
        {"browserTab":{"targetId":"T1","profile":"openclaw","target":"node","node":"n1","url":"https://example.com/a",
          "title":"\(long)","extra":"dropped","nested":{"a":1}},
         "aggregated":"big output","tail":"x","snapshot":"huge","exitCode":0}
        """)
        let kept = try #require(ToolActivity.fileEditDetails(details))
        let tab = try #require(kept["browserTab"]?.object)
        #expect(tab["targetId"]?.string == "T1" && tab["profile"]?.string == "openclaw" && tab["target"]?.string == "node" && tab["node"]?.string == "n1")
        #expect(tab["url"]?.string == "https://example.com/a")
        #expect((tab["title"]?.string?.count ?? 0) <= 512, "title is capped")
        #expect(tab["extra"] == nil && tab["nested"] == nil, "other tab keys are dropped")
        #expect(kept["aggregated"] == nil && kept["tail"] == nil && kept["snapshot"] == nil, "bulky keys dropped")
        #expect(kept["exitCode"]?.int == 0)
        let tooLong = Fixtures.json("{\"browserTab\":{\"targetId\":\"T1\",\"profile\":\"p\",\"target\":\"host\",\"url\":\"\(longURL)\"}}")
        let capped = ToolActivity.fileEditDetails(tooLong)?["browserTab"]?.object?["url"]?.string
        #expect(capped == nil || capped!.count <= 2048, "an overlong url is dropped or capped, never kept whole")
    }

    // MARK: History and live

    static func historyItems(imageBlock: String = #"{"type":"image","mimeType":"image/png","omitted":true,"bytes":48211}"#,
                             target: String = "T1", url: String = "https://example.com/a", id: String = "c1") -> [ChatItem] {
        [ChatItem(Fixtures.json("""
         {"role":"assistant","content":[{"type":"toolCall","id":"\(id)","name":"browser","arguments":{"action":"navigate","url":"\(url)"}}],
          "__openclaw":{"id":"a-\(id)"}}
         """), fallbackIndex: 0)!,
         ChatItem(Fixtures.json("""
         {"role":"toolResult","toolCallId":"\(id)","toolName":"browser","isError":false,
          "content":[{"type":"text","text":"navigated"},\(imageBlock)],
          "details":{"browserTab":{"targetId":"\(target)","profile":"openclaw","target":"host","url":"\(url)","title":"Example"}},
          "__openclaw":{"id":"r-\(id)"}}
         """), fallbackIndex: 1)!]
    }

    static func tools(_ entries: [TranscriptEntry]) -> [ToolActivity] {
        entries.flatMap { entry -> [ToolActivity] in
            if case let .assistant(turn) = entry { return turn.tools }
            return []
        }
    }

    @Test func historyBuiltToolCarriesTheBrowserPage() throws {
        let items = Self.historyItems()
        #expect(items[1].toolDetails?["browserTab"]?.object?["url"]?.string == "https://example.com/a")
        let tool = try #require(Self.tools(TranscriptBuilder.build(items)).first)
        let page = try #require(tool.browserPage)
        #expect(page.toolCallId == "c1" && page.host == "example.com" && page.title == "Example")
        #expect(page.tabKey == "host|openclaw|T1")
    }

    @Test func omittedImageBlocksDoNotBreakTheCard() throws {
        let omitted = #"{"type":"image","omitted":true,"bytes":12}"#
        let tool = try #require(Self.tools(TranscriptBuilder.build(Self.historyItems(imageBlock: omitted))).first)
        #expect(tool.browserPage != nil && !tool.isError)
    }

    @Test func historyThroughTheTranscriptCacheKeepsTheCard() throws {
        let items = Self.historyItems()
        let data = try JSONEncoder().encode(TranscriptCache.Snapshot(items: items, complete: true))
        let loaded = try #require(TranscriptCache.decode(data).0?.items)
        #expect(Self.tools(TranscriptBuilder.build(loaded)).first?.browserPage?.host == "example.com")
    }

    @Test func liveToolResultEventCarriesTheBrowserPage() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let key = "agent:main:browser-live"
        let chat = GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                defaults: scratch.defaults, identity: Fixtures.identity()).chat(for: key)
        func event(_ data: JSONValue) {
            chat.handleAgent(["runId": "run_b", "sessionKey": .string(key), "stream": "tool", "data": data])
        }
        event(["phase": "start", "name": "browser", "toolCallId": "b1", "args": ["action": "open", "url": "https://example.com/live"]])
        #expect(Self.tools(chat.entries).first?.browserPage == nil, "no card while the call is running")
        event(Fixtures.json("""
        {"phase":"result","name":"browser","toolCallId":"b1","isError":false,
         "result":{"content":[{"type":"text","text":"opened"},{"type":"image","mimeType":"image/png","omitted":true,"bytes":900}],
                   "details":{"browserTab":{"targetId":"T9","profile":"openclaw","target":"host","url":"https://example.com/live","title":"Live"}}}}
        """))
        let page = try #require(Self.tools(chat.entries).first?.browserPage)
        #expect(page.url.absoluteString == "https://example.com/live" && page.title == "Live" && page.tabKey == "host|openclaw|T9")
    }

    // MARK: Dedup

    static func tool(_ id: String, tab: String, url: String, error: Bool = false) -> ToolActivity {
        ToolActivity(id: id, name: "browser", arguments: nil, result: "ok",
                     details: Fixtures.json("{\"browserTab\":{\"targetId\":\"\(tab)\",\"profile\":\"p\",\"target\":\"host\",\"url\":\"\(url)\"}}"),
                     isError: error, isRunning: false)
    }

    @Test func latestPerTabKeepsOnlyTheNewestResultOfEachTabInOrder() {
        let tools = [Self.tool("a", tab: "T1", url: "https://x.com/1"), Self.tool("b", tab: "T2", url: "https://y.com/"),
                     Self.tool("c", tab: "T1", url: "https://x.com/2"), Self.tool("d", tab: "T1", url: "https://x.com/3", error: true)]
        let latest = BrowserPagePreview.latestPerTab(tools)
        #expect(latest.map(\.toolCallId) == ["b", "c"], "ordered by each tab's latest result; the failed call has no card (\(latest.map(\.toolCallId)))")
        #expect(latest.last?.url.absoluteString == "https://x.com/2")
        #expect(BrowserPagePreview.latestPerTab([]).isEmpty)
    }

    @Test func latestPerTabCapsAtTheMostRecentTabs() {
        let tools = (1...5).map { Self.tool("c\($0)", tab: "T\($0)", url: "https://x.com/\($0)") }
        #expect(BrowserPagePreview.latestPerTab(tools).map(\.toolCallId) == ["c3", "c4", "c5"], "default limit is 3, newest tabs, in order")
        #expect(BrowserPagePreview.latestPerTab(tools, limit: 2).map(\.toolCallId) == ["c4", "c5"])
        #expect(BrowserPagePreview.latestPerTab(tools, limit: 0).isEmpty)
        let revisit = tools + [Self.tool("c6", tab: "T1", url: "https://x.com/again")]
        #expect(BrowserPagePreview.latestPerTab(revisit).map(\.toolCallId) == ["c4", "c5", "c6"], "revisiting a tab moves it to the end")
    }

    @Test func differentProfilesAndNodesAreDifferentTabs() {
        func tool(_ id: String, _ tab: String) -> ToolActivity {
            ToolActivity(id: id, name: "browser", arguments: nil, result: "ok", details: Fixtures.json(tab), isError: false, isRunning: false)
        }
        let a = tool("a", #"{"browserTab":{"targetId":"T","profile":"p1","target":"host","url":"https://a.com"}}"#)
        let b = tool("b", #"{"browserTab":{"targetId":"T","profile":"p2","target":"host","url":"https://a.com"}}"#)
        let c = tool("c", #"{"browserTab":{"targetId":"T","profile":"p1","target":"node","node":"n","url":"https://a.com"}}"#)
        #expect(BrowserPagePreview.latestPerTab([a, b, c], limit: 10).map(\.toolCallId) == ["a", "b", "c"])
    }

    // MARK: Footer

    @Test func footerFallsBackFromTabTitleToLinkTitleToHost() throws {
        let titled = try #require(Self.parse(Self.tab(url: #""url":"https://example.com/docs/page?q=1""#)))
        #expect(titled.footer(linkTitle: "Link").title == "Example Docs" && titled.footer(linkTitle: "Link").subtitle == "example.com/docs/page?q=1",
                "the tab title wins and line 2 is the whole URL")
        let untitled = try #require(Self.parse(Self.tab(url: #""url":"https://example.com/docs/page?q=1""#, title: "")))
        let linked = untitled.footer(linkTitle: "  Link Title ")
        #expect(linked.title == "Link Title" && linked.subtitle == "example.com/docs/page?q=1")
        let host = untitled.footer(linkTitle: nil)
        #expect(host.title == "example.com" && host.subtitle == "/docs/page?q=1", "line 1 fell back to the host, so line 2 is path + query")
        #expect(untitled.footer(linkTitle: "  ").title == "example.com", "a blank link title is ignored")
        let root = try #require(Self.parse(Self.tab(url: #""url":"https://example.com/""#, title: "")))
        #expect(root.footer(linkTitle: nil).title == "example.com" && root.footer(linkTitle: nil).subtitle == "example.com", "a root path shows the full display URL")
    }

    // MARK: Screenshot hook

    @Test func screenshotAppliesOnlyToTheLatestTurnShowingTheTab() {
        func turn(_ id: String, _ tools: [ToolActivity]) -> TranscriptEntry {
            .assistant(AssistantTurn(id: id, tools: tools))
        }
        let entries = [turn("t1", [Self.tool("a", tab: "T1", url: "https://x.com/1"), Self.tool("b", tab: "T2", url: "https://y.com/")]),
                       turn("t2", [Self.tool("c", tab: "T1", url: "https://x.com/2")]),
                       turn("t3", [])]
        let latest = BrowserPagePreview.latestTurnIds(entries)
        #expect(latest["host|p|T1"] == "t2", "T1's newest card is in t2; t1's keeps its og:image")
        #expect(latest["host|p|T2"] == "t1")
        #expect(latest.count == 2)
    }
}
