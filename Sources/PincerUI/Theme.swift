import PincerKit
import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

enum Theme {
    static let bubbleCorner: CGFloat = 14

    static func color(named name: String?) -> Color? {
        guard let name = name?.lowercased() else { return nil }
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple", "violet": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        default:
            return Color(hex: name)
        }
    }

    /// Glass toolbar buttons draw their own circle on macOS 26 / iOS 26, so glyphs drop the ring.
    static var moreSymbol: String {
        if #available(macOS 26, iOS 26, *) { "ellipsis" } else { "ellipsis.circle" }
    }

    static var filterSymbol: String {
        if #available(macOS 26, iOS 26, *) { "line.3.horizontal.decrease" } else { "line.3.horizontal.decrease.circle" }
    }

    static var sidebarBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var codeBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.6)
        #else
        Color(uiColor: .tertiarySystemBackground)
        #endif
    }
}

// MARK: Liquid Glass

/// Liquid Glass on macOS 26 / iOS 26, with a material fallback on earlier systems.
extension View {
    /// A floating glass surface, like a toolbar or composer, clipped to `shape`.
    @ViewBuilder
    func glassSurface(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.clear), in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
    }

    /// Prominent glass for primary actions (Send, Connect); bordered-prominent on earlier systems.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary glass buttons; bordered on earlier systems.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Lets neighbouring glass shapes blend and morph into each other.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Soft scroll-edge fade under floating chrome (macOS 26 / iOS 26).
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255)
    }
}

enum Owner {
    /// The person using Pincer. User turns are rendered as this person, not as a channel alias.
    static var displayName: String {
        if let custom = UserDefaults.standard.string(forKey: "pincer.ownerName"), !custom.isEmpty { return custom }
        #if os(macOS)
        let full = NSFullUserName()
        return full.isEmpty ? "You" : full
        #else
        return "You"
        #endif
    }

    static var initials: String {
        let words = self.displayName.split(separator: " ")
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct Avatar: View {
    let text: String
    var emoji: String?
    var color: Color = .accentColor
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(self.color.gradient)
            if let emoji {
                Text(emoji).font(.system(size: self.size * 0.55))
            } else {
                Text(self.text)
                    .font(.system(size: self.size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

extension Date {
    var chatTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return self.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(self) {
            return "Yesterday \(self.formatted(date: .omitted, time: .shortened))"
        }
        return self.formatted(date: .abbreviated, time: .shortened)
    }
}

extension Date {
    /// Full date and time, with seconds, for a message's details line.
    var messageDetailTimestamp: String {
        self.formatted(date: .abbreviated, time: .standard)
    }
}

extension Image {
    init(cgImage: CGImage) {
        self.init(decorative: cgImage, scale: 1)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
