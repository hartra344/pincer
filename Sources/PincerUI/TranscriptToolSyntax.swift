import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Token colors for JSON and code in tool cards. Light shades all pass 4.5:1 on white; dark shades
/// pass 7:1 on the dark card background.
enum TranscriptSyntaxColors {
    static let key = adaptive(light: 0x0550AE, dark: 0x79C0FF)
    static let string = adaptive(light: 0x953800, dark: 0xFFA657)
    static let number = adaptive(light: 0x116329, dark: 0x7EE787)
    static let keyword = adaptive(light: 0x6639BA, dark: 0xD2A8FF)
    static let comment = adaptive(light: 0x57606A, dark: 0x8B949E)

    static func color(_ kind: ToolSyntax.TokenKind) -> PColor {
        switch kind {
        case .key: self.key
        case .string: self.string
        case .number: self.number
        case .keyword: self.keyword
        case .comment: self.comment
        }
    }

    /// The light and dark shades of a kind, as 0xRRGGBB.
    static func hex(_ kind: ToolSyntax.TokenKind) -> (light: Int, dark: Int) {
        switch kind {
        case .key: (0x0550AE, 0x79C0FF)
        case .string: (0x953800, 0xFFA657)
        case .number: (0x116329, 0x7EE787)
        case .keyword: (0x6639BA, 0xD2A8FF)
        case .comment: (0x57606A, 0x8B949E)
        }
    }

    private static func adaptive(light: Int, dark: Int) -> PColor {
        func color(_ rgb: Int) -> PColor {
            let (r, g, b) = (CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
            #if os(macOS)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            #else
            return UIColor(red: r, green: g, blue: b, alpha: 1)
            #endif
        }
        let (lightColor, darkColor) = (color(light), color(dark))
        #if os(macOS)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor }
        #else
        return UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
        #endif
    }

    /// `text` with `tokens` colored. Only foreground colors change, so the string and Find's ranges stay as they were.
    static func apply(_ tokens: [ToolSyntax.Token], to text: NSAttributedString) -> NSAttributedString {
        guard !tokens.isEmpty else { return text }
        let colored = NSMutableAttributedString(attributedString: text)
        let length = colored.length
        for token in tokens {
            let range = NSIntersectionRange(token.range, NSRange(location: 0, length: length))
            if range.length > 0 { colored.addAttribute(.foregroundColor, value: self.color(token.kind), range: range) }
        }
        return colored
    }
}

/// Syntax tokens of a card's argument values and output, computed once next to the presentation.
struct ToolHighlights {
    /// Ranges in `ToolCallPresentation.argumentsText`.
    let arguments: [ToolSyntax.Token]
    /// Ranges in `ToolCallPresentation.Output.text`.
    let output: [ToolSyntax.Token]

    static let none = ToolHighlights(arguments: [], output: [])

    static func make(_ presentation: ToolCallPresentation) -> ToolHighlights {
        var arguments: [ToolSyntax.Token] = []
        var offset = 0
        for argument in presentation.arguments {
            let valueStart = offset + argument.key.utf16.count + 1
            if argument.isNested { arguments += ToolSyntax.jsonTokens(in: argument.value, offset: valueStart) }
            offset = valueStart + argument.value.utf16.count + 1
        }
        var output: [ToolSyntax.Token] = []
        if let result = presentation.output, !result.isError, !result.text.isEmpty {
            if presentation.kind == .read, let path = presentation.headline, let language = ToolSyntax.language(forPath: path) {
                output = ToolSyntax.tokens(in: result.text, language: language)
            } else if ToolSyntax.looksLikeJSON(result.text) {
                output = ToolSyntax.tokens(in: result.text, language: .json)
            }
        }
        return ToolHighlights(arguments: arguments, output: output)
    }
}
