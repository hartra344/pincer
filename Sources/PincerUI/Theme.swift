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
    static let accent = Color(red: 0.93, green: 0.33, blue: 0.24) // lobster

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
