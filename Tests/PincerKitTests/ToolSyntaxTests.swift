import Foundation
import Testing
@testable import PincerKit

/// #342: the tool-card tokenizer is pure, bounded and only reports ranges.
@Suite("Tool syntax")
struct ToolSyntaxTests {
    typealias Kind = ToolSyntax.TokenKind

    static func spans(_ text: String, _ language: ToolSyntax.Language) -> [(Kind, String)] {
        let ns = text as NSString
        return ToolSyntax.tokens(in: text, language: language).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    static func has(_ spans: [(Kind, String)], _ kind: Kind, _ text: String) -> Bool {
        spans.contains { $0.0 == kind && $0.1 == text }
    }

    @Test func jsonKeysStringsNumbersLiterals() {
        let s = Self.spans(#"{"name": "pincer", "count": -12.5e3, "ok": true, "none": null, "list": [1, "x"]}"#, .json)
        #expect(Self.has(s, .key, "\"name\""), "\(s)")
        #expect(Self.has(s, .string, "\"pincer\""))
        #expect(Self.has(s, .number, "-12.5e3"))
        #expect(Self.has(s, .keyword, "true") && Self.has(s, .keyword, "null"))
        #expect(Self.has(s, .number, "1") && Self.has(s, .string, "\"x\""))
        #expect(!s.contains { $0.0 == .string && $0.1 == "\"name\"" }, "a key is not also a string")
    }

    @Test func jsonEscapedQuotesStayInsideTheString() {
        let s = Self.spans(#"{"q": "say \"hi\" now", "n": 1}"#, .json)
        #expect(Self.has(s, .string, #""say \"hi\" now""#), "\(s)")
        #expect(Self.has(s, .number, "1"))
    }

    @Test func unterminatedStringEndsAtTheEndOfTheText() {
        let text = #"{"a": "never closed"#
        let tokens = ToolSyntax.tokens(in: text, language: .json)
        let length = (text as NSString).length
        for token in tokens { #expect(NSMaxRange(token.range) <= length) }
        #expect(tokens.contains { $0.kind == .string })
    }

    @Test func swiftKeywordsStringsNumbersComments() {
        let s = Self.spans("""
        // header comment
        func add(_ a: Int) -> Int { let x = 42; return a + x } /* tail */
        let s = "he said \\"hi\\""
        """, .swift)
        #expect(Self.has(s, .comment, "// header comment"), "\(s)")
        #expect(Self.has(s, .keyword, "func") && Self.has(s, .keyword, "return") && Self.has(s, .keyword, "let"))
        #expect(Self.has(s, .number, "42"))
        #expect(Self.has(s, .comment, "/* tail */"))
        #expect(Self.has(s, .string, "\"he said \\\"hi\\\"\""))
    }

    @Test func keywordsInsideWordsAndStringsAreNotKeywords() {
        let s = Self.spans(#"let letter = "func in string"; funcy()"#, .swift)
        #expect(!Self.has(s, .keyword, "letter") && !Self.has(s, .keyword, "funcy"), "\(s)")
        #expect(!s.contains { $0.0 == .keyword && $0.1 == "func" }, "\(s)")
    }

    @Test func pythonHashCommentsAndTripleQuotes() {
        let s = Self.spans("def f(x):  # note\n    \"\"\"doc\nstring\"\"\"\n    return None\n", .python)
        #expect(Self.has(s, .keyword, "def") && Self.has(s, .keyword, "return") && Self.has(s, .keyword, "None"), "\(s)")
        #expect(Self.has(s, .comment, "# note"))
        #expect(s.contains { $0.0 == .string && $0.1.hasPrefix("\"\"\"doc") && $0.1.hasSuffix("string\"\"\"") }, "\(s)")
    }

    @Test func shellCommentsAndKeywords() {
        let s = Self.spans("#!/bin/sh\nif [ -f a ]; then echo \"hi $USER\"; fi # done\nexport N=3\n", .shell)
        #expect(Self.has(s, .comment, "#!/bin/sh"), "\(s)")
        #expect(Self.has(s, .keyword, "if") && Self.has(s, .keyword, "then") && Self.has(s, .keyword, "fi"))
        #expect(Self.has(s, .string, "\"hi $USER\""))
        #expect(Self.has(s, .comment, "# done"))
    }

    @Test func languageByExtension() {
        #expect(ToolSyntax.language(forPath: "a/b/File.swift") == .swift)
        #expect(ToolSyntax.language(forPath: "x.TS") == .javascript)
        #expect(ToolSyntax.language(forPath: "x.py") == .python)
        #expect(ToolSyntax.language(forPath: "run.sh") == .shell)
        #expect(ToolSyntax.language(forPath: "data.json") == .json)
        #expect(ToolSyntax.language(forPath: "README.md") == nil)
        #expect(ToolSyntax.language(forPath: "Makefile") == nil)
        #expect(ToolSyntax.language(forPath: ".gitignore") == nil)
    }

    @Test func looksLikeJSON() {
        #expect(ToolSyntax.looksLikeJSON("{\"a\": 1}") && ToolSyntax.looksLikeJSON("  [1, 2]") && ToolSyntax.looksLikeJSON("[\n  {\"a\": 1}]"))
        #expect(!ToolSyntax.looksLikeJSON("plain words") && !ToolSyntax.looksLikeJSON("{ oops") && !ToolSyntax.looksLikeJSON(""))
        #expect(!ToolSyntax.looksLikeJSON("{"))
    }

    @Test func tokensAreOrderedNonOverlappingAndInBounds() {
        let texts = [#"{"a": [1, 2, {"b": "c"}], "d": null}"#, "let a = \"x\" // c\nfunc f() {}\n", "é😀 \"🙂\" 12 // 🙂\nlet ü = 1"]
        for text in texts {
            for language in [ToolSyntax.Language.json, .swift, .python, .shell, .javascript, .cFamily, .yaml] {
                let length = (text as NSString).length
                var end = 0
                for token in ToolSyntax.tokens(in: text, language: language) {
                    #expect(token.range.location >= end && token.range.length > 0 && NSMaxRange(token.range) <= length,
                            "\(language) \(token.range) in \(text.debugDescription)")
                    end = NSMaxRange(token.range)
                }
            }
        }
    }

    @Test func emptyAndWhitespaceInput() {
        for language in [ToolSyntax.Language.json, .swift, .python, .shell] {
            #expect(ToolSyntax.tokens(in: "", language: language).isEmpty)
            #expect(ToolSyntax.tokens(in: " \n\t\n", language: language).isEmpty)
        }
    }

    @Test func hugeAdversarialInputIsBoundedAndLinear() {
        let inputs = [
            String(repeating: "\"", count: 200_000),
            String(repeating: "\\\"", count: 100_000),
            "\"" + String(repeating: "a", count: 300_000),
            String(repeating: "/*", count: 100_000),
            String(repeating: "[{", count: 100_000),
            String(repeating: "0123456789.e+-", count: 20_000),
            String(repeating: "func let var // \"x\n", count: 15_000),
            "\"\"\"" + String(repeating: "q\n", count: 100_000),
        ]
        let clock = ContinuousClock()
        for language in [ToolSyntax.Language.json, .swift, .python, .shell, .javascript] {
            for input in inputs {
                let elapsed = clock.measure { _ = ToolSyntax.tokens(in: input, language: language) }
                #expect(elapsed < PerfBudget.limit(.seconds(1)) * 4, "\(language) \(input.prefix(6)) \(elapsed)")
            }
        }
    }
}
