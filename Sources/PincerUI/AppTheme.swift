import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Light, Dark, or following the system.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    #if os(macOS)
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// A color the theme can set. Each has a system default used when neither the preset nor the
/// user sets it.
enum ThemeRole: String, CaseIterable, Identifiable, Sendable {
    case accent, link, ownerAvatar, agentAvatar, chatBackground, sidebarBackground, codeBackground

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .accent: "Accent"
        case .link: "Links"
        case .ownerAvatar: "Your avatar"
        case .agentAvatar: "Agent avatar"
        case .chatBackground: "Chat background"
        case .sidebarBackground: "Sidebar background"
        case .codeBackground: "Code background"
        }
    }

    var storageKey: String { "pincer.theme.color.\(self.rawValue)" }
}

/// One color for light mode and one for dark, as 0xRRGGBB.
struct ThemeColor: Hashable, Sendable {
    let light: UInt32
    let dark: UInt32

    init(_ light: UInt32, _ dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    init(_ both: UInt32) { self.init(both, both) }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        self.init(int)
    }

    var platformColor: PColor {
        let light = PColor(rgb: self.light), dark = PColor(rgb: self.dark)
        guard self.light != self.dark else { return light }
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        #else
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }

    var color: Color {
        #if os(macOS)
        Color(nsColor: self.platformColor)
        #else
        Color(uiColor: self.platformColor)
        #endif
    }
}

/// Built-in palettes. `standard` keeps Pincer's original look: system accent and backgrounds.
enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case standard, lobster, ocean, forest, grape, sunset, graphite, midnight

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .standard: "Default"
        case .lobster: "Lobster"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .grape: "Grape"
        case .sunset: "Sunset"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        }
    }

    /// nil leaves the role at its system default.
    func color(_ role: ThemeRole) -> ThemeColor? {
        switch self {
        case .standard:
            nil
        case .lobster:
            switch role {
            case .accent: ThemeColor(0xE8543D, 0xF0654E)
            case .link: ThemeColor(0xC9412B, 0xFF7A63)
            case .ownerAvatar: ThemeColor(0x2F7FD8, 0x4A92E6)
            case .agentAvatar: ThemeColor(0xE8543D, 0xF0654E)
            case .chatBackground: ThemeColor(0xFFF8F5, 0x1E1614)
            case .sidebarBackground: ThemeColor(0xFBEFEA, 0x251A17)
            case .codeBackground: ThemeColor(0xF7E6E0, 0x2E211D)
            }
        case .ocean:
            switch role {
            case .accent: ThemeColor(0x0A84C6, 0x3FB0E8)
            case .link: ThemeColor(0x0071A8, 0x5CC4F2)
            case .ownerAvatar: ThemeColor(0x1E6BB8, 0x5B9BE0)
            case .agentAvatar: ThemeColor(0x13A5A5, 0x34C4C4)
            case .chatBackground: ThemeColor(0xF4F9FC, 0x0F1A22)
            case .sidebarBackground: ThemeColor(0xE8F2F8, 0x14222C)
            case .codeBackground: ThemeColor(0xDDECF5, 0x1A2C38)
            }
        case .forest:
            switch role {
            case .accent: ThemeColor(0x2E8B57, 0x4CC080)
            case .link: ThemeColor(0x23724A, 0x6BD49A)
            case .ownerAvatar: ThemeColor(0x3B7A57, 0x5FAF84)
            case .agentAvatar: ThemeColor(0x8A6D3B, 0xC49A58)
            case .chatBackground: ThemeColor(0xF6FAF5, 0x121A14)
            case .sidebarBackground: ThemeColor(0xEAF3E7, 0x17221A)
            case .codeBackground: ThemeColor(0xE0EDDB, 0x1F2E22)
            }
        case .grape:
            switch role {
            case .accent: ThemeColor(0x8E44AD, 0xB57EDC)
            case .link: ThemeColor(0x7D3C98, 0xC39BE6)
            case .ownerAvatar: ThemeColor(0x5B5FC7, 0x8B8FF0)
            case .agentAvatar: ThemeColor(0xC0399B, 0xE26BC0)
            case .chatBackground: ThemeColor(0xFAF6FC, 0x19131E)
            case .sidebarBackground: ThemeColor(0xF1E8F6, 0x211828)
            case .codeBackground: ThemeColor(0xEADCF2, 0x2A1F33)
            }
        case .sunset:
            switch role {
            case .accent: ThemeColor(0xE67E22, 0xF39C4A)
            case .link: ThemeColor(0xC0392B, 0xFF8A65)
            case .ownerAvatar: ThemeColor(0xD35400, 0xF5A05A)
            case .agentAvatar: ThemeColor(0xE74C3C, 0xFF6F61)
            case .chatBackground: ThemeColor(0xFFF9F2, 0x1F1712)
            case .sidebarBackground: ThemeColor(0xFDEEDC, 0x2A1E16)
            case .codeBackground: ThemeColor(0xFAE3C8, 0x35261B)
            }
        case .graphite:
            switch role {
            case .accent: ThemeColor(0x5E6670, 0x9AA3AD)
            case .link: ThemeColor(0x3E4A56, 0xA9B6C3)
            case .ownerAvatar: ThemeColor(0x6B7280, 0x9CA3AF)
            case .agentAvatar: ThemeColor(0x4B5563, 0xB0B8C1)
            case .chatBackground: ThemeColor(0xF7F7F8, 0x161718)
            case .sidebarBackground: ThemeColor(0xEEEFF1, 0x1D1F21)
            case .codeBackground: ThemeColor(0xE6E7EA, 0x26282B)
            }
        case .midnight:
            switch role {
            case .accent: ThemeColor(0x4F6BED, 0x7B93FF)
            case .link: ThemeColor(0x3D5AFE, 0x8C9EFF)
            case .ownerAvatar: ThemeColor(0x5C6BC0, 0x7986CB)
            case .agentAvatar: ThemeColor(0x7C4DFF, 0xB388FF)
            case .chatBackground: ThemeColor(0xF3F4FA, 0x0B0E1A)
            case .sidebarBackground: ThemeColor(0xE7E9F5, 0x111527)
            case .codeBackground: ThemeColor(0xDCDFF0, 0x1A1F36)
            }
        }
    }

    /// Colors shown on the preset's swatch in Settings.
    var swatch: [Color] {
        let roles: [ThemeRole] = [.accent, .agentAvatar, .ownerAvatar]
        return roles.map { self.color($0)?.color ?? AppTheme.systemDefault($0) }
    }
}

/// The theme in effect: a preset, the appearance mode, and any colors the user picked themselves.
/// Read from UserDefaults, so every window and the native transcript/sidebar agree.
struct AppTheme: Equatable, Sendable {
    static let presetKey = "pincer.theme.preset"
    static let modeKey = "pincer.theme.mode"

    var preset: ThemePreset = .standard
    var mode: AppearanceMode = .system
    var overrides: [ThemeRole: ThemeColor] = [:]

    static var current: AppTheme {
        let defaults = UserDefaults.standard
        var theme = AppTheme()
        theme.preset = defaults.string(forKey: self.presetKey).flatMap(ThemePreset.init) ?? .standard
        theme.mode = defaults.string(forKey: self.modeKey).flatMap(AppearanceMode.init) ?? .system
        for role in ThemeRole.allCases {
            if let hex = defaults.string(forKey: role.storageKey), let color = ThemeColor(hex: hex) {
                theme.overrides[role] = color
            }
        }
        return theme
    }

    /// The role's color from the user or the preset; nil means the system default.
    func value(_ role: ThemeRole) -> ThemeColor? {
        self.overrides[role] ?? self.preset.color(role)
    }

    func platformColor(_ role: ThemeRole) -> PColor? {
        self.value(role)?.platformColor
    }

    /// The role's color, falling back to the system default.
    func color(_ role: ThemeRole) -> Color {
        self.value(role)?.color ?? Self.systemDefault(role)
    }

    /// Only set when the theme changes the background, so the default keeps system materials.
    func background(_ role: ThemeRole) -> Color? {
        self.value(role)?.color
    }

    /// The accent when the theme sets one; nil keeps the system accent (and its behavior when the
    /// window is inactive).
    var tint: Color? { self.value(.accent)?.color }

    var accent: Color { self.color(.accent) }

    static func systemDefault(_ role: ThemeRole) -> Color {
        #if os(macOS)
        Color(nsColor: self.systemPlatformDefault(role))
        #else
        Color(uiColor: self.systemPlatformDefault(role))
        #endif
    }

    static func systemPlatformDefault(_ role: ThemeRole) -> PColor {
        #if os(macOS)
        switch role {
        case .accent: .controlAccentColor
        case .link: .linkColor
        case .ownerAvatar: .systemBlue
        case .agentAvatar: PColor(rgb: 0xED543D)
        case .chatBackground: .windowBackgroundColor
        case .sidebarBackground: .windowBackgroundColor
        case .codeBackground: NSColor.textBackgroundColor.withAlphaComponent(0.6)
        }
        #else
        switch role {
        case .accent: .tintColor
        case .link: .link
        case .ownerAvatar: .systemBlue
        case .agentAvatar: PColor(rgb: 0xED543D)
        case .chatBackground: .systemBackground
        case .sidebarBackground: .secondarySystemBackground
        case .codeBackground: .tertiarySystemBackground
        }
        #endif
    }

    // MARK: Saving

    static func setOverride(_ color: Color?, for role: ThemeRole) {
        if let hex = color?.rgbHex {
            UserDefaults.standard.set(hex, forKey: role.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: role.storageKey)
        }
    }

    static func resetOverrides() {
        for role in ThemeRole.allCases { UserDefaults.standard.removeObject(forKey: role.storageKey) }
    }
}

extension EnvironmentValues {
    @Entry var appTheme = AppTheme()
}

extension PColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// "#RRGGBB" in sRGB, for storing a picked color.
    var rgbHex: String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

/// Applies the theme to a window: appearance mode, accent, and the `appTheme` environment value.
private struct ThemeRoot: ViewModifier {
    @State private var theme = AppTheme.current

    func body(content: Content) -> some View {
        content
            .environment(\.appTheme, self.theme)
            .tint(self.theme.tint)
            #if os(iOS)
            .preferredColorScheme(self.theme.mode.colorScheme)
            #endif
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
                let theme = AppTheme.current
                if theme != self.theme { self.theme = theme }
            }
            #if os(macOS)
            .onChange(of: self.theme.mode, initial: true) { _, mode in
                NSApplication.shared.appearance = mode.nsAppearance
            }
            #endif
    }
}

extension View {
    func themed() -> some View {
        self.modifier(ThemeRoot())
    }
}
