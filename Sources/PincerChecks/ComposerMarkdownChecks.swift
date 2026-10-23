import Foundation
import PincerKit

/// #1067: the Markdown-aware composer's pure logic, offline.
@MainActor
func runComposerMarkdownChecks() {
    func slice(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }
    func apply(_ edit: ComposerEdit?, to text: String) -> (text: String, selection: NSRange)? {
        guard let edit else { return nil }
        let ns = text as NSString
        guard edit.range.location >= 0, NSMaxRange(edit.range) <= ns.length else { return nil }
        return (ns.replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    // Tokenizer
    let styled = "a **bold** _it_ ~~x~~ `c` [t](u) 😀 **你好**"
    let spans = ComposerMarkdown.tokenize(styled)
    func kinds(_ kind: ComposerMarkdownKind) -> [String] { spans.filter { $0.kind == kind }.map { slice(styled, $0.contentRange) } }
    check(kinds(.strong) == ["bold", "你好"], "tokenizer finds strong spans with UTF-16 content ranges past emoji")
    check(kinds(.emphasis) == ["it"] && kinds(.strikethrough) == ["x"] && kinds(.inlineCode) == ["c"], "tokenizer finds emphasis, strike and code")
    check(kinds(.link) == ["t"], "tokenizer finds links")
    check(ComposerMarkdown.tokenize("snake_case_name").isEmpty, "intraword underscore is not emphasis")
    check(ComposerMarkdown.tokenize("**open `tick").isEmpty, "unclosed markers produce no spans")
    check(ComposerMarkdown.tokenize("\\*no\\*").isEmpty, "escaped markers produce no spans")
    check(ComposerMarkdown.tokenize("`**x**`").filter { $0.kind == .strong }.isEmpty, "code spans suppress inline styling")
    let fenced = ComposerMarkdown.tokenize("```\n**x**\n```\n- a")
    check(fenced.filter { $0.kind == .codeFence }.count == 2 && fenced.filter { $0.kind == .codeBlock }.count == 1
          && fenced.filter { $0.kind == .strong }.isEmpty && fenced.filter { $0.kind == .listItem }.count == 1,
          "fences mark code block lines and suppress styling inside")

    // Incremental index
    var text = "one **a**\n```\ncode\n```\ntwo" as NSString
    var index = ComposerMarkdownIndex(text: text)
    check(index.isInsideCodeBlock(text.range(of: "code").location) && !index.isInsideCodeBlock(0), "index knows code block lines")
    text = text.replacingCharacters(in: NSRange(location: 3, length: 0), with: "x") as NSString
    let restyled = index.update(text: text, editedRange: NSRange(location: 3, length: 1), changeInLength: 1)
    check(restyled.length <= 12, "an ordinary keystroke restyles only its paragraph (\(restyled.length))")
    check(Set(index.spans(in: text, range: NSRange(location: 0, length: text.length))) == Set(ComposerMarkdown.tokenize(text as String)),
          "index spans match a full tokenize after an edit")

    // Formatting
    func toggle(_ style: ComposerInlineStyle, _ text: String, _ sel: NSRange) -> String? {
        apply(ComposerFormatting.toggle(style, in: text as NSString, selection: sel), to: text)?.text
    }
    check(toggle(.bold, "a b c", NSRange(location: 2, length: 1)) == "a **b** c", "bold wraps the selection")
    check(toggle(.bold, "a **b** c", NSRange(location: 4, length: 1)) == "a b c", "bold unwraps when markers sit outside the selection")
    check(toggle(.inlineCode, "ab", NSRange(location: 1, length: 0)) == "a``b", "empty selection inserts an empty pair")
    check(toggle(.italic, "x", NSRange(location: 0, length: 1)) == "_x_" && toggle(.strikethrough, "x", NSRange(location: 0, length: 1)) == "~~x~~",
          "italic and strikethrough markers")
    if let link = apply(ComposerFormatting.toggleLink(in: "foo" as NSString, selection: NSRange(location: 0, length: 3)), to: "foo") {
        check(link.text.hasPrefix("[foo](") && link.selection.length > 0, "link wraps the selection and selects the url")
    } else { check(false, "link toggle returned an edit") }
    check(apply(ComposerFormatting.toggleLink(in: "[foo](u)" as NSString, selection: NSRange(location: 2, length: 0)), to: "[foo](u)")?.text == "foo",
          "link unwraps from inside")
    check(apply(ComposerFormatting.toggleList(in: "a\nb" as NSString, selection: NSRange(location: 0, length: 3)), to: "a\nb")?.text == "- a\n- b",
          "toggleList adds bullets to every line")
    check(apply(ComposerFormatting.toggleList(in: "- a\n- b" as NSString, selection: NSRange(location: 0, length: 7)), to: "- a\n- b")?.text == "a\nb",
          "toggleList removes bullets when all lines are list items")

    // Newline continuation
    func newline(_ text: String) -> String? {
        apply(ComposerFormatting.newline(in: text as NSString, selection: NSRange(location: (text as NSString).length, length: 0)), to: text)?.text
    }
    check(newline("- a") == "- a\n- " && newline("* a") == "* a\n* " && newline("+ a") == "+ a\n+ ", "bullet lists continue")
    check(newline("1. a") == "1. a\n2. " && newline("1) a") == "1) a\n2) ", "numbered lists increment")
    check(newline("- [x] a") == "- [x] a\n- [ ] ", "task items continue unchecked")
    check(newline("> q") == "> q\n> ", "quotes continue")
    check(newline("  - a") == "  - a\n  - ", "indentation is kept")
    check(newline("plain") == nil, "plain lines are left to the text view")
    check(newline("- a\n- ")?.hasSuffix("- a\n") == true, "an empty item ends the list")
    let indented = apply(ComposerFormatting.indent(in: "- a" as NSString, selection: NSRange(location: 3, length: 0), outdent: false), to: "- a")
    check(indented?.text == "  - a", "indent adds two spaces to a bullet")
    func marked(_ text: String, outdent: Bool? = nil) -> String? {
        let t = text as NSString
        let edit = outdent.map { ComposerFormatting.indent(in: t, selection: NSRange(location: t.length, length: 0), outdent: $0) }
            ?? ComposerFormatting.newline(in: t, selection: NSRange(location: t.length, length: 0))
        return edit.flatMap { apply($0, to: text)?.text }
    }
    check(marked("1. a\n2. b\n3. c", outdent: false) == "1. a\n2. b\n   1. c", "Tab on an ordered item restarts the sublist at 1")
    check(marked("1. a\n   1. b\n   2. c", outdent: true) == "1. a\n   1. b\n2. c", "Shift-Tab renumbers against the parent level")
    check(marked("1. a\n   1. b\n2. c", outdent: false) == "1. a\n   1. b\n   2. c", "Tab adopts the previous sibling's number")
    check(marked("1. a\n   1. b\n   2. ") == "1. a\n   1. b\n2. ", "Enter on an empty nested numbered item outdents it")
    check(marked("- a\n  - b\n  - ") == "- a\n  - b\n- ", "Enter on an empty nested bullet outdents it")
    check(marked("1. a\n2. ") == "1. a\n", "Enter on an empty top-level item still exits the list")
    check(marked("* a\n* b\n* ") == "* a\n* b\n", "Enter on an empty * item exits without leaving a literal *")
    check(ComposerReturnKey.resolve(source: .hardware, hasMarkedText: false, shift: false, option: true, command: false,
                                    supportsSendAndOpen: false, canSubmit: true) == .newline,
          "Option-Return (insertNewlineIgnoringFieldEditor:) takes the list-aware newline path")
    check(ComposerFormatting.indent(in: "hello" as NSString, selection: NSRange(location: 0, length: 0), outdent: false) == nil,
          "indent falls through off list lines")

    // Fence auto-close
    let opened = apply(ComposerFormatting.autoCloseFence(in: "```" as NSString, typedAt: 2), to: "```")
    check(opened?.text == "```\n```" && opened?.selection == NSRange(location: 3, length: 0), "typing an opening fence inserts the closing one")
    check(ComposerFormatting.autoCloseFence(in: "```\nx\n```" as NSString, typedAt: 8) == nil, "a closing fence is left alone")

    // Rich text → Markdown
    check(RichTextToMarkdown.markdown(fromHTML: "a <b>b</b> <i>i</i> <del>d</del> <code>c</code>")?.contains("**b**") == true,
          "HTML inline styles become Markdown")
    check(RichTextToMarkdown.markdown(fromHTML: "<a href=\"https://x.dev\">t</a>")?.contains("[t](https://x.dev)") == true, "HTML links become Markdown links")
    check(RichTextToMarkdown.markdown(fromHTML: "<ul><li>a</li><li>b</li></ul>")?.contains("- b") == true, "HTML lists become bullets")
    check(RichTextToMarkdown.markdown(fromHTML: "<script>alert(1)</script><b>ok</b>")?.contains("alert") == false, "HTML scripts are dropped")
    check(RichTextToMarkdown.markdown(fromHTML: "<span style=\"color:red\">plain</span>") == nil, "formatting-free HTML returns nil")

    // Settings
    let suiteName = "pincer.checks.composer-markdown.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suiteName) {
        let settings = ComposerMarkdownSettings(defaults: defaults)
        check(settings.liveStyling && !settings.showsFormatBar, "composer Markdown settings default to styling on, format bar off")
        settings.liveStyling = false
        settings.showsFormatBar = true
        check(!ComposerMarkdownSettings(defaults: defaults).liveStyling && ComposerMarkdownSettings(defaults: defaults).showsFormatBar,
              "composer Markdown settings persist")
        check(defaults.object(forKey: ComposerMarkdownSettings.liveStylingKey) != nil, "live styling uses its documented key")
        defaults.removePersistentDomain(forName: suiteName)
    } else { check(false, "throwaway defaults suite") }
}

/// Typing-latency smoke: tokenize a 20k-UTF-16 draft, then 200 incremental index updates.
@MainActor
func runComposerMarkdownPerfChecks() {
    let block = "# Heading\nSome **bold** and _italic_ text with `code` and [a link](https://example.com/x) 😀 你好\n- item one\n> quote ~~gone~~\n```\nlet x = 1 // **raw**\n```\n\n"
    var draft = ""
    while (draft as NSString).length < 20_000 { draft += block }
    let ns = draft as NSString

    let fullStart = ContinuousClock.now
    let spans = ComposerMarkdown.tokenize(draft)
    let full = ContinuousClock.now - fullStart
    print("  tokenize \(ns.length) UTF-16: \(spans.count) spans in \(full)")
    checkBudget(full, .milliseconds(30), hardLimit: .milliseconds(500), "a 20k draft tokenizes in under 30 ms")

    var text = ns
    var index = ComposerMarkdownIndex(text: text)
    var worst = Duration.zero
    var total = Duration.zero
    var widest = 0
    for i in 0..<200 {
        let paragraphStart = ComposerMarkdown.paragraphRange(in: text, covering: NSRange(location: (i * 9973) % (text.length - 1), length: 0))
        if text.substring(with: paragraphStart).hasPrefix("```") { continue }
        let location = paragraphStart.location + min(2, paragraphStart.length)
        text = text.replacingCharacters(in: NSRange(location: location, length: 0), with: "x") as NSString
        let edited = NSRange(location: location, length: 1)
        let start = ContinuousClock.now
        let range = index.update(text: text, editedRange: edited, changeInLength: 1)
        _ = index.spans(in: text, range: range)
        let elapsed = ContinuousClock.now - start
        total += elapsed
        worst = max(worst, elapsed)
        widest = max(widest, range.length)
    }
    print("  200 incremental updates: total \(total), worst \(worst), widest range \(widest)")
    check(widest < 2_000, "ordinary keystrokes restyle a small range (\(widest) UTF-16)")
    checkBudget(total, .milliseconds(100), hardLimit: .seconds(2), "200 incremental updates on a 20k draft stay under 100 ms total")
}
