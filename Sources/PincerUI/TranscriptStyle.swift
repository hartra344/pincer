import PincerKit
#if os(macOS)
import AppKit
typealias PFont = NSFont
typealias PColor = NSColor
typealias PView = NSView
typealias PBezierPath = NSBezierPath
#else
import UIKit
typealias PFont = UIFont
typealias PColor = UIColor
typealias PView = UIView
typealias PBezierPath = UIBezierPath
#endif

/// Fonts for native transcript rows. Rebuilt when the system text size changes (iOS Dynamic Type),
/// and everything laid out with the old fonts is thrown away with it.
@MainActor
final class TranscriptStyle {
    private(set) static var shared = TranscriptStyle()
    /// Bumped by `reload()`, so caches keyed on style can tell they're stale.
    private(set) static var generation = 0

    static func reload() {
        self.shared = TranscriptStyle()
        self.generation += 1
    }

    let body: PFont
    let bodySemibold: PFont
    let headline: PFont
    let callout: PFont
    let calloutMedium: PFont
    let calloutMonoMedium: PFont
    let code: PFont
    let caption: PFont
    let captionSemibold: PFont
    let captionMono: PFont
    let caption2Medium: PFont
    let title2: PFont
    let title3: PFont
    let listMarker: PFont

    init() {
        let body = Self.font(.body)
        let callout = Self.font(.callout)
        let caption = Self.font(.caption1)
        self.body = body
        self.bodySemibold = Self.weighted(body, .semibold)
        self.headline = Self.font(.headline)
        self.callout = callout
        self.calloutMedium = Self.weighted(callout, .medium)
        self.calloutMonoMedium = PFont.monospacedSystemFont(ofSize: callout.pointSize, weight: .medium)
        self.code = PFont.monospacedSystemFont(ofSize: callout.pointSize, weight: .regular)
        self.caption = caption
        self.captionSemibold = Self.weighted(caption, .semibold)
        self.captionMono = PFont.monospacedSystemFont(ofSize: caption.pointSize, weight: .regular)
        self.caption2Medium = Self.weighted(Self.font(.caption2), .medium)
        self.title2 = Self.weighted(Self.font(.title2), .bold)
        self.title3 = Self.weighted(Self.font(.title3), .bold)
        self.listMarker = PFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
    }

    static func font(_ style: PFont.TextStyle) -> PFont {
        #if os(macOS)
        NSFont.preferredFont(forTextStyle: style, options: [:])
        #else
        UIFont.preferredFont(forTextStyle: style)
        #endif
    }

    static func weighted(_ font: PFont, _ weight: PFont.Weight) -> PFont {
        PFont.systemFont(ofSize: font.pointSize, weight: weight)
    }

    /// Height of one line of `font`, the way TextKit lays it out.
    static func lineHeight(_ font: PFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func withTraits(_ font: PFont, bold: Bool, italic: Bool) -> PFont {
        guard bold || italic else { return font }
        #if os(macOS)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    static func rounded(size: CGFloat, weight: PFont.Weight) -> PFont {
        let font = PFont.systemFont(ofSize: size, weight: weight)
        #if os(macOS)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
        #else
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }
}

/// Semantic colors for native transcript rows. All dynamic, so they follow light/dark mode.
enum TranscriptColors {
    #if os(macOS)
    static var label: PColor { .labelColor }
    static var secondary: PColor { .secondaryLabelColor }
    static var tertiary: PColor { .tertiaryLabelColor }
    static var stroke: PColor { .quaternaryLabelColor }
    #if compiler(>=6.4) // Xcode 27 SDK renamed it back
    static var fill: PColor { .quinaryLabelColor }
    #else
    static var fill: PColor { .quinaryLabel }
    #endif
    static var strongFill: PColor { .quaternaryLabelColor }
    static var separator: PColor { .separatorColor }
    static var codeBackground: PColor { NSColor.textBackgroundColor.withAlphaComponent(0.6) }
    static var link: PColor { .linkColor }
    static var tint: PColor { .controlAccentColor }
    static var highlight: PColor { .quaternaryLabelColor }
    #else
    static var label: PColor { .label }
    static var secondary: PColor { .secondaryLabel }
    static var tertiary: PColor { .tertiaryLabel }
    static var stroke: PColor { .separator }
    static var fill: PColor { .quaternarySystemFill }
    static var strongFill: PColor { .tertiarySystemFill }
    static var separator: PColor { .separator }
    static var codeBackground: PColor { .tertiarySystemBackground }
    static var link: PColor { .link }
    static var tint: PColor { .tintColor }
    static var highlight: PColor { .systemFill }
    #endif
    static var red: PColor { .systemRed }
    static var blue: PColor { .systemBlue }
    static let accent = PColor(red: 0.93, green: 0.33, blue: 0.24, alpha: 1)
}

/// Spacing shared by row layout and row views. Mirrors the old SwiftUI rows.
enum TranscriptMetrics {
    static let sidePadding: CGFloat = 16
    static let verticalPadding: CGFloat = 6
    static let avatar: CGFloat = 32
    static let avatarGap: CGFloat = 12
    static let headerGap: CGFloat = 4
    static let blockSpacing: CGFloat = 8
    static let toolSpacing: CGFloat = 4
    /// Space between two messages in the same turn.
    static let messageSpacing: CGFloat = 14
    static let footerSpacing: CGFloat = 4
    static let maxCardWidth: CGFloat = 640
    static let cardRadius: CGFloat = 8
    static let iconBox: CGFloat = 16
    static let toolOutputMaxHeight: CGFloat = 240
    static let toolOutputLimit = 20000

    static var contentX: CGFloat { self.sidePadding + self.avatar + self.avatarGap }
}

extension PBezierPath {
    static func rounded(_ rect: CGRect, radius: CGFloat) -> PBezierPath {
        #if os(macOS)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #else
        UIBezierPath(roundedRect: rect, cornerRadius: radius)
        #endif
    }
}

/// SF Symbols drawn straight into a view's `draw(_:)`.
@MainActor
enum TranscriptSymbols {
    enum Weight: Hashable { case regular, medium, semibold, bold }

    private struct Key: Hashable {
        let name: String
        let size: CGFloat
        let weight: Weight
    }

    private static var cache: [Key: PlatformImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: Weight = .regular) -> PlatformImage? {
        let key = Key(name: name, size: size, weight: weight)
        if let cached = self.cache[key] { return cached }
        #if os(macOS)
        let symbolWeight: NSFont.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: symbolWeight))
        #else
        let symbolWeight: UIImage.SymbolWeight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: symbolWeight))
        #endif
        if let image { self.cache[key] = image }
        return image
    }

    /// Draws the symbol centered in `rect`, shrunk to fit if needed.
    static func draw(_ name: String, in rect: CGRect, size: CGFloat, weight: Weight = .regular, color: PColor) {
        guard let image = self.image(name, size: size, weight: weight) else { return }
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return }
        let scale = min(1, rect.width / natural.width, rect.height / natural.height)
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        let target = CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                            width: drawn.width, height: drawn.height)
        #if os(macOS)
        let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? image
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
        image.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: target)
        #endif
    }
}
