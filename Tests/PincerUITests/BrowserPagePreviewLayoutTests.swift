import CoreGraphics
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #976: the browser page card in the transcript.
@MainActor
@Suite("Browser page preview card")
struct BrowserPagePreviewLayoutTests {
    static func tool(_ id: String, tab: String = "t1", url: String = "https://example.com/docs?a=1",
                     title: String? = "Example Docs") -> ToolActivity
    {
        var tabInfo: [String: JSONValue] = ["targetId": .string(tab), "profile": .string("openclaw"),
                                            "target": .string("host"), "url": .string(url)]
        if let title { tabInfo["title"] = .string(title) }
        return ToolActivity(id: id, name: "browser", arguments: #"{"action":"navigate"}"#, result: "ok",
                            details: .object(["browserTab": .object(tabInfo)]), isError: false, isRunning: false)
    }

    static func make(tools: [ToolActivity], streaming: Bool = false, expanded: Bool = false, thinking: String = "hm",
                     text: [String] = ["Here is the page."], width: CGFloat = 600, latest: Bool = false,
                     configure: (GatewayStore) -> Void = { _ in }) -> (TranscriptRowLayout, GatewayStore)
    {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let key = "agent:main:page-card"
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        configure(gateway)
        let disclosure = TranscriptDisclosure()
        disclosure.set("steps:turn-page", expanded: expanded)
        let context = TranscriptContext(gateway: gateway, disclosure: disclosure,
                                        agent: AgentSummary(id: "main", name: "Main"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        var turn = AssistantTurn(id: "turn-page", timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = tools
        turn.thinking = thinking.isEmpty ? [] : [thinking]
        turn.text = text
        turn.textIds = text.map { _ in nil }
        turn.isStreaming = streaming
        let pageTurns = latest ? BrowserPagePreview.latestTurnIds([.assistant(turn)]) : [:]
        let builder = TranscriptLayoutBuilder(context: context, settings: .current(for: context), pageTurns: pageTurns)
        return (builder.layout(.entry(.assistant(turn)), width: width), gateway)
    }

    static func cards(_ layout: TranscriptRowLayout) -> [TranscriptRowLayout.Placed] {
        layout.parts.filter { $0.part.kind == .pagePreview }
    }

    static func ref(_ name: String, width: Int? = nil, height: Int? = nil) -> ImageRef {
        ImageRef(artifactId: nil, base64: name, url: nil, mimeType: "image/png", alt: nil, width: width, height: height)
    }

    @Test func cardSitsAfterTheStepsAndBeforeTheReplyText() throws {
        for expanded in [false, true] {
            let (layout, _) = Self.make(tools: [Self.tool("c1")], expanded: expanded)
            let kinds = layout.parts.map(\.part.kind)
            let card = try #require(kinds.firstIndex(of: .pagePreview))
            let text = try #require(kinds.lastIndex(of: .text))
            // With steps hidden by default the cards lead the reply area.
            if let header = kinds.firstIndex(of: .thinkingHeader) { #expect(header < card) }
            #expect(card < text, "expanded=\(expanded)")
            if expanded, let tool = kinds.firstIndex(of: .tool) { #expect(tool < card) }
            #expect(Self.cards(layout).count == 1)
        }
    }

    @Test func cardWithoutAnImageIsAFooterBarOnly() throws {
        let (layout, _) = Self.make(tools: [Self.tool("c1")])
        let placed = try #require(Self.cards(layout).first)
        guard case let .pagePreview(card) = placed.part else { return }
        #expect(card.kind == .none && card.imageHeight == 0)
        #expect(placed.frame.height == card.footerHeight)
        #expect(placed.frame.width <= 320)
        #expect(card.title == "Example Docs")
    }

    @Test func linkPreviewImageReservesAFixedBoxBeforeItDecodes() throws {
        let og = Self.ref("og")
        let (layout, _) = Self.make(tools: [Self.tool("c1")]) { gateway in
            gateway.pagePreviews.seed(LinkPreview(title: nil, image: og, favicon: nil), for: URL(string: "https://example.com/docs?a=1")!)
        }
        let placed = try #require(Self.cards(layout).first)
        guard case let .pagePreview(card) = placed.part else { return }
        #expect(card.kind == .og && card.image == nil)
        #expect(card.imageHeight == (placed.frame.width / 1.91).rounded())
        #expect(layout.images.contains(og), "the row relayouts when the image is decoded")
    }

    @Test func screenshotWinsAndIsCappedAt240() throws {
        let shot = Self.ref("shot", width: 1000, height: 3000)
        let (layout, _) = Self.make(tools: [Self.tool("c1")], streaming: true) { gateway in
            gateway.pagePreviews.setScreenshot(shot, forTab: "host|openclaw|t1")
        }
        guard case let .pagePreview(card)? = Self.cards(layout).first?.part else { Issue.record("no card"); return }
        #expect(card.kind == .screenshot && card.imageHeight == 240)
        #expect(!card.loadsPreview, "nothing is fetched while the turn streams")
    }

    @Test func finishedLatestTurnShowsTheScreenshot() {
        let shot = Self.ref("shot-done", width: 1000, height: 3000)
        let (latest, _) = Self.make(tools: [Self.tool("c1")], latest: true) { gateway in
            gateway.pagePreviews.setScreenshot(shot, forTab: "host|openclaw|t1")
        }
        guard case let .pagePreview(card)? = Self.cards(latest).first?.part else { Issue.record("no card"); return }
        #expect(card.kind == .screenshot && card.imageHeight == 240)
        let (older, _) = Self.make(tools: [Self.tool("c1")]) { gateway in
            gateway.pagePreviews.setScreenshot(shot, forTab: "host|openclaw|t1")
        }
        guard case let .pagePreview(old)? = Self.cards(older).first?.part else { Issue.record("no card"); return }
        #expect(old.kind == .none, "an older turn keeps its og:image, not the live screenshot")
    }

    @Test func accessibilityLabelHasNoLeadingSeparator() {
        let (layout, _) = Self.make(tools: [Self.tool("c1")], thinking: "", text: [])
        #expect(!layout.accessibilityLabel.hasPrefix("."))
        #expect(!layout.accessibilityLabel.contains(".."))
    }

    @Test func oneCardPerTabAndAtMostThree() {
        let tools = [Self.tool("a", tab: "t1"), Self.tool("b", tab: "t1", url: "https://example.com/b"),
                     Self.tool("c", tab: "t2"), Self.tool("d", tab: "t3"), Self.tool("e", tab: "t4"), Self.tool("f", tab: "t5")]
        let (layout, _) = Self.make(tools: tools)
        #expect(Self.cards(layout).count == 3)
        let (dedup, _) = Self.make(tools: Array(tools.prefix(2)))
        #expect(Self.cards(dedup).count == 1)
    }

    @Test func accessibilityOffersOpenAndCopyLink() {
        let (layout, _) = Self.make(tools: [Self.tool("c1")])
        #expect(layout.accessibilityLabel.contains("Example Docs"))
        let names = TranscriptRowAccessibilityAction.actions(for: layout, actions: nil, anchor: PView()).map(\.name)
        #expect(names.contains(L("Open Example Docs")))
        #expect(names.contains(L("Copy Link")))
    }

    @Test func tapGoesThroughTheHook() {
        let (_, gateway) = Self.make(tools: [])
        var opened: BrowserPagePreview?
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "main", name: "Main"), sessionKey: "k",
                                        previewImage: { _ in }, saveFile: { _, _ in },
                                        openBrowserPage: { opened = $0; return true })
        let renderer = TranscriptRenderer(context: context)
        let page = Self.tool("c1").browserPage!
        renderer.openBrowserPage(page)
        #expect(opened == page)
    }

    @Test func decodingTheImageDoesNotChangeTheRowHeight() throws {
        let og = Self.ref("og-jump")
        let url = URL(string: "https://example.com/docs?a=1")!
        var before: CGFloat = 0
        var after: CGFloat = 0
        _ = Self.make(tools: [Self.tool("c1")]) { gateway in
            gateway.pagePreviews.seed(LinkPreview(title: nil, image: og, favicon: nil), for: url)
        }
        let (first, _) = Self.make(tools: [Self.tool("c1")]) { gateway in
            gateway.pagePreviews.seed(LinkPreview(title: nil, image: og, favicon: nil), for: url)
        }
        before = first.height
        let (second, _) = Self.make(tools: [Self.tool("c1")]) { gateway in
            gateway.pagePreviews.seed(LinkPreview(title: nil, image: og, favicon: nil), for: url)
            guard let cg = Self.pixel() else { return }
            gateway.images.store(cg, key: og.cacheKey)
        }
        after = second.height
        guard case let .pagePreview(card)? = Self.cards(second).first?.part else { Issue.record("no card"); return }
        #expect(card.image != nil, "the decoded image is drawn")
        #expect(before == after, "arrival of pixels must not move rows below the card")
    }

    static func pixel() -> CGImage? {
        CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
}
