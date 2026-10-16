import Foundation
import PincerKit

// Page-preview card for `browser` tool calls (#976): upstream-shaped `details.browserTab`
// parsed offline, from the built-in demo, and from the mock Gateway (`controlUi.linkPreview`).

private func browserDetails(target: String = "T1", url: String = "https://example.com/docs?q=1", title: String? = "  Example Docs ") -> JSONValue {
    let titleField = title.map { #","title":"\#($0)""# } ?? ""
    return json(#"{"browserTab":{"targetId":"\#(target)","profile":"openclaw","target":"host","url":"\#(url)"\#(titleField)}}"#)
}

private func browserTool(_ id: String, details: JSONValue?, isError: Bool = false) -> ToolActivity {
    ToolActivity(id: id, name: "browser", arguments: nil, result: "ok", details: details, isError: isError, isRunning: false)
}

@MainActor
func runBrowserPagePreviewChecks() async {
    let page = BrowserPagePreview.parse(toolName: "browser", details: browserDetails(), isError: false, toolCallId: "c1")
    check(page?.host == "example.com" && page?.title == "Example Docs" && page?.displayTitle == "Example Docs"
          && page?.displayURL == "example.com/docs?q=1" && page?.tabKey == "host|openclaw|T1",
          "browser page: parses host, trimmed title, display URL and tab key (\(page?.tabKey ?? "nil"))")
    let noTitle = BrowserPagePreview.parse(toolName: "browser", details: browserDetails(title: "  "), isError: false, toolCallId: "c1")
    check(noTitle?.title == nil && noTitle?.displayTitle == "example.com", "browser page: a blank title falls back to the host")
    let node = BrowserPagePreview.parse(
        toolName: "browser",
        details: json(#"{"browserTab":{"targetId":"T1","profile":"p","target":"node","node":"mini","url":"http://a.com/"}}"#),
        isError: false, toolCallId: "c2")
    check(node?.tabKey == "node|mini|p|T1" && node?.displayURL == "a.com", "browser page: node target keys include the node")
    check(BrowserPagePreview.parse(toolName: "browser", details: browserDetails(), isError: true, toolCallId: "c") == nil
          && BrowserPagePreview.parse(toolName: "web_fetch", details: browserDetails(), isError: false, toolCallId: "c") == nil
          && BrowserPagePreview.parse(toolName: "browser", details: browserDetails(url: "file:///etc/hosts"), isError: false, toolCallId: "c") == nil
          && BrowserPagePreview.parse(toolName: "browser", details: json(#"{"browserTab":{"profile":"p","target":"host","url":"https://a.com"}}"#),
                                      isError: false, toolCallId: "c") == nil,
          "browser page: errors, other tools, non-http URLs and a missing targetId have no card")

    let kept = ToolActivity.fileEditDetails(json(#"{"browserTab":{"targetId":"T1","profile":"p","target":"host","url":"https://a.com","junk":"x"},"aggregated":"big"}"#))
    check(kept?["browserTab"]?["targetId"]?.string == "T1" && kept?["browserTab"]?["junk"] == nil && kept?["aggregated"] == nil,
          "browser page: fileEditDetails keeps a trimmed browserTab and drops bulky keys")

    let items = [
        ChatItem(json(#"{"role":"assistant","content":[{"type":"toolCall","id":"h1","name":"browser","arguments":{"action":"open","url":"https://example.com/a"}}],"__openclaw":{"id":"ha"}}"#), fallbackIndex: 0)!,
        ChatItem(json("""
        {"role":"toolResult","toolCallId":"h1","toolName":"browser","isError":false,
         "content":[{"type":"text","text":"opened"},{"type":"image","omitted":true,"bytes":4096}],
         "details":{"browserTab":{"targetId":"T1","profile":"openclaw","target":"host","url":"https://example.com/a","title":"A"}},
         "__openclaw":{"id":"hr"}}
        """), fallbackIndex: 1)!,
    ]
    let built = TranscriptBuilder.build(items).flatMap { entry -> [ToolActivity] in
        if case let .assistant(turn) = entry { return turn.tools }
        return []
    }
    check(built.first?.browserPage?.title == "A" && built.first?.browserPage?.host == "example.com",
          "browser page: a history-built tool (with an omitted image block) carries browserPage")

    let tools = [browserTool("a", details: browserDetails(target: "T1", url: "https://x.com/1")),
                 browserTool("b", details: browserDetails(target: "T2", url: "https://y.com/")),
                 browserTool("c", details: browserDetails(target: "T1", url: "https://x.com/2")),
                 browserTool("d", details: browserDetails(target: "T1", url: "https://x.com/3"), isError: true)]
    let latest = BrowserPagePreview.latestPerTab(tools)
    check(latest.map(\.toolCallId) == ["b", "c"] && latest.last?.url.absoluteString == "https://x.com/2",
          "browser page: latestPerTab keeps the newest successful result per tab, in order (\(latest.map(\.toolCallId)))")
    let many = (1...5).map { browserTool("m\($0)", details: browserDetails(target: "T\($0)", url: "https://x.com/\($0)")) }
    check(BrowserPagePreview.latestPerTab(many).map(\.toolCallId) == ["m3", "m4", "m5"]
          && BrowserPagePreview.latestPerTab(many, limit: 1).map(\.toolCallId) == ["m5"],
          "browser page: latestPerTab caps at the 3 most recent tabs")
    let untitled = BrowserPagePreview.parse(toolName: "browser", details: browserDetails(title: nil), isError: false, toolCallId: "u")
    check(page?.footer(linkTitle: "L").title == "Example Docs" && untitled?.footer(linkTitle: " L ").title == "L"
          && untitled?.footer(linkTitle: nil).title == "example.com" && untitled?.footer(linkTitle: nil).subtitle == "/docs?q=1",
          "browser page: footer falls back from tab title to link title to host + path")

    let previews = BrowserPagePreviews()
    let shot = ImageRef(artifactId: nil, base64: "AAAA", url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil)
    previews.setScreenshot(shot, forTab: "host|openclaw|T1")
    check(previews.screenshot(forTab: "host|openclaw|T1") == shot && previews.screenshot(forTab: "host|openclaw|T2") == nil,
          "browser page: the screenshot hook is keyed per tab")
    previews.setScreenshot(nil, forTab: "host|openclaw|T1")
    check(previews.screenshot(forTab: "host|openclaw|T1") == nil, "browser page: clearing the screenshot hook works")
    let url = URL(string: "https://example.com/a")!
    previews.load(url)
    check(previews.preview(for: url) == nil, "browser page: load without a connected, advertising gateway is a no-op")
}

private let toolCardsKey = "agent:main:dashboard:tool-cards"

@MainActor
private func browserCards(_ chat: ChatStore) -> [ToolActivity] {
    chat.entries.flatMap { entry -> [ToolActivity] in
        if case let .assistant(turn) = entry { return turn.tools.filter { $0.browserPage != nil } }
        return []
    }
}

@MainActor
private func checkBrowserCards(_ gateway: GatewayStore, label: String) async {
    let chat = gateway.chat(for: toolCardsKey)
    await chat.load()
    let loaded = await waitFor("\(label) browser card history") { !browserCards(chat).isEmpty }
    check(loaded, "\(label): the tool-cards chat has a browser result with a page card")
    guard let tool = browserCards(chat).first, let page = tool.browserPage else { return }
    check(tool.name == "browser" && !tool.isError && !page.host.isEmpty && !page.displayTitle.isEmpty
          && ["http", "https"].contains(page.url.scheme ?? ""),
          "\(label): browser card has a title (\(page.displayTitle)) and http(s) URL (\(page.url))")
    check(page.title?.isEmpty == false, "\(label): browser card carries a page title (\(page.title ?? "nil"))")
    #if DEBUG && os(macOS)
    if gateway.profile.isDemo { checkBrowserCardRouting(gateway, page: page, label: label) }
    #endif
    check(gateway.advertises("controlUi.linkPreview"), "\(label): the gateway advertises controlUi.linkPreview")
    gateway.pagePreviews.load(page.url)
    let resolved = await waitFor("\(label) link preview", timeout: 10) { gateway.pagePreviews.preview(for: page.url)?.image != nil }
    check(resolved, "\(label): controlUi.linkPreview resolves an image for \(page.url.host ?? "")")
    let preview = gateway.pagePreviews.preview(for: page.url)
    check(preview?.image?.base64?.isEmpty == false && preview?.image?.mimeType?.hasPrefix("image/") == true,
          "\(label): the preview image is an inline image")
    check(preview?.favicon?.base64?.isEmpty == false, "\(label): the preview has a favicon")
    let before = gateway.pagePreviews.preview(for: page.url)
    gateway.pagePreviews.load(page.url)
    check(gateway.pagePreviews.preview(for: page.url) == before, "\(label): a cached preview is served again unchanged")
    #if DEBUG
    await checkLinkPreviewLimits(gateway.pagePreviews, label: label)
    #endif
}

#if DEBUG
@MainActor
private func checkLinkPreviewLimits(_ previews: BrowserPagePreviews, label: String) async {
    let start = previews.requestCount
    for text in ["http://localhost:3000/", "http://127.0.0.1/", "http://192.168.1.10/a", "http://10.0.0.5/", "https://printer.local/", "http://8.8.8.8/"] {
        previews.load(URL(string: text)!)
    }
    check(previews.requestCount == start, "\(label): loopback, private, .local and IP-literal hosts are never requested")

    let urls = (1...8).map { URL(string: "https://empty-\($0).example.com/")! }
    for url in urls { previews.load(url) }
    check(previews.requestCount - start == 4, "\(label): at most 4 linkPreview requests are in flight (\(previews.requestCount - start))")
    let drained = await waitFor("\(label) queued link previews", timeout: 15) { previews.requestCount - start == 8 }
    check(drained, "\(label): queued requests start as earlier ones finish (\(previews.requestCount - start))")
    // The `{}` answers must settle before the negative-cache check.
    try? await Task.sleep(for: .milliseconds(500))
    let settled = previews.requestCount
    for url in urls { previews.load(url) }
    check(previews.requestCount == settled && urls.allSatisfy { previews.preview(for: $0) == nil },
          "\(label): an empty {} answer is a cached negative: no retry, no preview")
}
#endif

@MainActor
func runDemoBrowserPagePreview() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for browser page preview", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for browser page preview connected")
    guard connected else { return }
    defer { gateway.stop() }
    await checkBrowserCards(gateway, label: "demo")
}

@MainActor
func runLiveBrowserPagePreview(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock browser page", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("mock for browser page preview", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "mock for browser page preview connected")
    guard connected else { return }
    defer { gateway.stop() }
    await checkBrowserCards(gateway, label: "mock")
}
