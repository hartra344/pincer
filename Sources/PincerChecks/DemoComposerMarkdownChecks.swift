import Foundation
@testable import PincerKit

/// The demo's "Release notes" chat holds a user message typed with Markdown; the composer styles the same text as you type.
@MainActor
func runDemoComposerMarkdownChecks() async {
    let (gateway, connected) = await startStore(.demo(), waiting: "demo for composer Markdown", timeout: 25, reconnect: true)
    defer { gateway.stop() }
    check(connected, "demo connected")
    guard connected else { return }
    let key = DemoGateway.markdownComposeKey
    check(gateway.sessions[key]?.title == "Release notes", "demo has the Release notes chat")
    let chat = gateway.chat(for: key)
    await chat.load()
    func sent() -> String? {
        for case let .user(item) in chat.entries { return item.plainText }
        return nil
    }
    let loaded = await waitFor("release notes history") { sent() != nil }
    guard loaded, let text = sent() else { check(false, "demo user message loads"); return }
    check(text == DemoGateway.markdownComposeMessage, "demo sends the Markdown as typed, markers included")

    let ns = text as NSString
    let spans = ComposerMarkdown.tokenize(text)
    func count(_ kind: ComposerMarkdownKind) -> Int { spans.filter { $0.kind == kind }.count }
    func content(_ kind: ComposerMarkdownKind) -> [String] {
        spans.filter { $0.kind == kind }.map { ns.substring(with: $0.contentRange) }
    }
    check(content(.strong) == ["1.1 release notes", "Markdown composing"], "demo message has two bold spans")
    check(content(.strikethrough) == ["Dark mode toggle"], "demo message has a struck-through span")
    check(content(.inlineCode) == ["⌘B", "⌘I", "⌘E", "⇧Return", "Tab", "⇧Tab"], "demo message has inline code spans")
    check(content(.link) == ["the checklist"], "demo message has a link")
    check(content(.heading(2)) == ["What's new"], "demo message has a level-2 heading")
    check(count(.listItem) == 5, "demo message has five list items, including nested and numbered (got \(count(.listItem)))")
    check(count(.blockquote) == 1, "demo message has a blockquote")
    check(count(.codeFence) == 2 && count(.codeBlock) == 1, "demo message has one fenced code block")

    // Inside the fence, inline syntax is inert.
    check(spans.filter { $0.kind == .strong }.allSatisfy { span in
        !spans.contains { $0.kind == .codeBlock && NSIntersectionRange($0.range, span.range).length > 0 }
    }, "no inline span lands inside the code block")
}
