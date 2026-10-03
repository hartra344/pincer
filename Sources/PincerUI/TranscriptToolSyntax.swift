import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Token colors for JSON and code in tool cards. Existing shades are kept when they already meet
/// the contrast target on the surface where the token is drawn.
enum TranscriptSyntaxColors {
    enum Surface: Equatable { case card, terminal }

    /// Palette resolution is keyed by the actual packed background as well as appearance traits,
    /// since semantic system fills can change without a light/dark or contrast-mode change.
    final class ResolutionCache: @unchecked Sendable {
        private struct Key: Hashable {
            let background: UInt32
            let dark: Bool
            let increasedContrast: Bool
        }

        private let limit = 16
        private let lock = NSLock()
        private var values: [Key: UInt32] = [:]
        private var order: [Key] = []

        var count: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values.count
        }

        func value(background: UInt32, dark: Bool, increasedContrast: Bool) -> UInt32? {
            self.lock.lock()
            defer { self.lock.unlock() }
            let key = Key(background: background, dark: dark, increasedContrast: increasedContrast)
            guard let value = self.values[key] else { return nil }
            self.order.removeAll { $0 == key }
            self.order.append(key)
            return value
        }

        func insert(_ value: UInt32, background: UInt32, dark: Bool, increasedContrast: Bool) {
            self.lock.lock()
            defer { self.lock.unlock() }
            let key = Key(background: background, dark: dark, increasedContrast: increasedContrast)
            self.order.removeAll { $0 == key }
            self.values[key] = value
            self.order.append(key)
            if self.order.count > self.limit, let oldest = self.order.first {
                self.order.removeFirst()
                self.values.removeValue(forKey: oldest)
            }
        }
    }

    static func hex(_ kind: ToolSyntax.TokenKind) -> (light: Int, dark: Int) {
        switch kind {
        case .key: (0x0550AE, 0x79C0FF)
        case .string: (0x953800, 0xFFA657)
        case .number: (0x116329, 0x7EE787)
        case .keyword: (0x6639BA, 0xD2A8FF)
        case .comment: (0x57606A, 0x8B949E)
        }
    }

    /// `text` with syntax tokens colored against their actual card or terminal surface.
    /// Color resolution is dynamic, but policy work is shared once per token kind for this string.
    static func apply(_ tokens: [ToolSyntax.Token], to text: NSAttributedString,
                      surface: Surface = .card, theme: AppTheme = .current, increasedContrast: Bool = false) -> NSAttributedString
    {
        guard !tokens.isEmpty else { return text }
        let colors = Dictionary(uniqueKeysWithValues: Set(tokens.map(\.kind)).map { kind in
            (kind, self.color(kind, surface: surface, theme: theme, increasedContrast: increasedContrast))
        })
        let colored = NSMutableAttributedString(attributedString: text)
        let length = colored.length
        for token in tokens {
            let range = NSIntersectionRange(token.range, NSRange(location: 0, length: length))
            if range.length > 0, let color = colors[token.kind] {
                colored.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        return colored
    }

    private static func color(_ kind: ToolSyntax.TokenKind, surface: Surface, theme: AppTheme, increasedContrast: Bool) -> PColor {
        let shades = self.hex(kind)
        #if os(macOS)
        let resolved = ResolutionCache()
        return NSColor(name: nil) { appearance in
            let dark = Self.isDark(appearance)
            let highContrast = increasedContrast || Self.isHighContrast(appearance)
            let background = Self.background(surface, theme: theme, appearance: appearance)
            if let cached = resolved.value(background: background, dark: dark, increasedContrast: highContrast) {
                return Self.nativeColor(cached)
            }
            let foreground = UInt32(dark ? shades.dark : shades.light)
            let adjusted = ToolSyntaxContrast.foreground(foreground, on: background, increased: highContrast)
            resolved.insert(adjusted, background: background, dark: dark, increasedContrast: highContrast)
            return Self.nativeColor(adjusted)
        }
        #else
        let resolved = ResolutionCache()
        return UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            let highContrast = increasedContrast || traits.accessibilityContrast == .high
            let background = Self.background(surface, theme: theme, traits: traits)
            if let cached = resolved.value(background: background, dark: dark, increasedContrast: highContrast) {
                return Self.nativeColor(cached)
            }
            let foreground = UInt32(dark ? shades.dark : shades.light)
            let adjusted = ToolSyntaxContrast.foreground(foreground, on: background, increased: highContrast)
            resolved.insert(adjusted, background: background, dark: dark, increasedContrast: highContrast)
            return Self.nativeColor(adjusted)
        }
        #endif
    }

    #if os(macOS)
    private struct RGBA { var red: Double; var green: Double; var blue: Double; var alpha: Double }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
         .accessibilityHighContrastVibrantDark].contains(appearance.name)
    }

    private static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
         .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark].contains(appearance.name)
    }

    private static func background(_ surface: Surface, theme: AppTheme, appearance: NSAppearance) -> UInt32 {
        let chatColor = theme.value(.chatBackground).map { Self.packed(Self.resolve($0.platformColor, appearance: appearance)) }
            ?? Self.packed(Self.resolve(AppTheme.systemPlatformDefault(.chatBackground), appearance: appearance))
        let cardColor = Self.composite(Self.resolve(Self.cardFill, appearance: appearance), over: chatColor)
        guard surface == .terminal else { return cardColor }
        let terminal: RGBA
        if let configured = theme.value(.codeBackground) {
            let rgb = Self.resolve(configured.platformColor, appearance: appearance)
            terminal = RGBA(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        } else {
            terminal = Self.resolve(NSColor.textBackgroundColor.withAlphaComponent(0.6), appearance: appearance)
        }
        return Self.composite(terminal, over: cardColor)
    }

    private static var cardFill: NSColor {
        #if compiler(>=6.4)
        .quinaryLabelColor
        #else
        .quinaryLabel
        #endif
    }

    private static func resolve(_ color: NSColor, appearance: NSAppearance) -> RGBA {
        var result: RGBA?
        appearance.performAsCurrentDrawingAppearance {
            if let resolved = color.usingColorSpace(.sRGB) {
                result = RGBA(red: resolved.redComponent, green: resolved.greenComponent,
                              blue: resolved.blueComponent, alpha: min(max(resolved.alphaComponent, 0), 1))
            }
        }
        return result ?? RGBA(red: 1, green: 1, blue: 1, alpha: 1)
    }

    private static func composite(_ foreground: RGBA, over background: UInt32) -> UInt32 {
        let a = foreground.alpha
        let base = Self.rgba(background)
        return Self.packed(RGBA(red: foreground.red * a + base.red * (1 - a),
                                green: foreground.green * a + base.green * (1 - a),
                                blue: foreground.blue * a + base.blue * (1 - a), alpha: 1))
    }

    private static func rgba(_ color: UInt32) -> RGBA {
        RGBA(red: Double((color >> 16) & 0xFF) / 255, green: Double((color >> 8) & 0xFF) / 255,
             blue: Double(color & 0xFF) / 255, alpha: 1)
    }

    private static func packed(_ color: RGBA) -> UInt32 {
        func byte(_ component: Double) -> UInt32 { UInt32((min(max(component, 0), 1) * 255).rounded()) }
        let r = byte(color.red), g = byte(color.green), b = byte(color.blue)
        return (r << 16) | (g << 8) | b
    }

    private static func nativeColor(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
    #else
    private struct RGBA { var red: Double; var green: Double; var blue: Double; var alpha: Double }

    private static func background(_ surface: Surface, theme: AppTheme, traits: UITraitCollection) -> UInt32 {
        let chat = theme.value(.chatBackground).map { Self.packed(Self.rgba($0.platformColor.resolvedColor(with: traits))) }
            ?? Self.packed(Self.rgba(AppTheme.systemPlatformDefault(.chatBackground).resolvedColor(with: traits)))
        let card = Self.composite(Self.rgba(TranscriptColors.fill.resolvedColor(with: traits)), over: chat)
        guard surface == .terminal else { return card }
        let terminal: RGBA
        if let configured = theme.value(.codeBackground) {
            terminal = Self.rgba(configured.platformColor.resolvedColor(with: traits))
        } else {
            terminal = Self.rgba(AppTheme.systemPlatformDefault(.codeBackground).resolvedColor(with: traits))
        }
        return Self.composite(terminal, over: card)
    }

    private static func rgba(_ color: UIColor) -> RGBA {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else
        {
            return RGBA(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return RGBA(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]),
                    alpha: min(max(Double(components.count > 3 ? components[3] : 1), 0), 1))
    }

    private static func composite(_ foreground: RGBA, over background: UInt32) -> UInt32 {
        let alpha = foreground.alpha
        let red = Double((background >> 16) & 0xFF) / 255
        let green = Double((background >> 8) & 0xFF) / 255
        let blue = Double(background & 0xFF) / 255
        return Self.packed(RGBA(red: foreground.red * alpha + red * (1 - alpha),
                                green: foreground.green * alpha + green * (1 - alpha),
                                blue: foreground.blue * alpha + blue * (1 - alpha), alpha: 1))
    }

    private static func packed(_ color: RGBA) -> UInt32 {
        func byte(_ component: Double) -> UInt32 { UInt32((min(max(component, 0), 1) * 255).rounded()) }
        let r = byte(color.red), g = byte(color.green), b = byte(color.blue)
        return (r << 16) | (g << 8) | b
    }

    private static func nativeColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
    #endif
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
