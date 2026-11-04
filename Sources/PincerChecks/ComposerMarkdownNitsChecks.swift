import Foundation
import PincerKit

/// #1069: numbered lists, quotes, headings, renumbering, `~~~` fences and indented code, offline.
@MainActor
func runComposerMarkdownNitsChecks() {
    func run(_ text: String, _ selection: NSRange, _ command: (NSString, NSRange) -> ComposerEdit) -> String {
        let edit = command(text as NSString, selection)
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
    func all(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    check(run("a\nb", all("a\nb"), ComposerFormatting.toggleNumberedList) == "1. a\n2. b", "Numbered List numbers every line")
    check(run("- a\n- b", all("- a\n- b"), ComposerFormatting.toggleNumberedList) == "1. a\n2. b", "Numbered List converts bullets")
    check(run("a\nb", all("a\nb"), ComposerFormatting.toggleQuote) == "> a\n> b", "Quote prefixes every line")
    check(run("> a", all("> a"), ComposerFormatting.toggleQuote) == "a", "Quote removes a level")
    check(run("a", NSRange(location: 0, length: 0), ComposerFormatting.toggleHeading) == "## a", "Heading adds a level-2 heading")
    check(run("## a", NSRange(location: 3, length: 0), ComposerFormatting.toggleHeading) == "a", "Heading removes the hashes")

    // Renumbering after the user's own change lands.
    let list = "1. a\n2. b\n3. c" as NSString
    let line = list.range(of: "2. b\n")
    let pending = ComposerTextFixups.renumberRange(in: list, replacing: line, with: "")
    let deleted = list.replacingCharacters(in: line, with: "") as NSString
    let fix = ComposerTextFixups.edit(in: deleted, typedFenceAt: nil, renumber: pending, selection: NSRange(location: line.location, length: 0))
    check(fix.map { deleted.replacingCharacters(in: $0.range, with: $0.replacement) } == "1. a\n2. c", "deleting an item renumbers the rest")
    check(ComposerTextFixups.renumberRange(in: list, replacing: NSRange(location: 4, length: 0), with: "x") == nil,
          "typing within a line doesn't renumber")
    let newline = ComposerFormatting.newline(in: "1. a\n2. b" as NSString, selection: NSRange(location: 4, length: 0))
    check(newline.map { ("1. a\n2. b" as NSString).replacingCharacters(in: $0.range, with: $0.replacement) } == "1. a\n2. \n3. b",
          "Return in the middle of a list renumbers the items below")

    // Fences and indented code.
    let tilde = ComposerMarkdown.tokenize("~~~\n**x**\n~~~")
    check(tilde.filter { $0.kind == .codeFence }.count == 2 && tilde.filter { $0.kind == .strong }.isEmpty, "~~~ fences are code")
    check(ComposerMarkdown.tokenize("~~~\n```\n**x**").filter { $0.kind == .strong }.isEmpty, "``` doesn't close a ~~~ fence")
    let close = ComposerFormatting.autoCloseFence(in: "~~~", typedAt: 2)
    check(close?.replacement.contains("~~~") == true, "typing ~~~ auto-closes the fence")
    let indented = "para\n\n    **x**" as NSString
    check(ComposerMarkdown.tokenize(indented as String).filter { $0.kind == .strong }.isEmpty
          && ComposerMarkdownIndex(text: indented).isInsideCodeBlock(indented.length - 1, in: indented), "indented lines after a blank line are code")
    check(ComposerMarkdown.tokenize("- a\n\n    **x**").filter { $0.kind == .strong }.count == 1, "an indented list item body isn't code")
}
