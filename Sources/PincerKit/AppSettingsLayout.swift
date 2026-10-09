import Foundation

/// One block of Pincer Settings (app-local preferences, never Gateway config).
public enum AppSettingsSection: String, CaseIterable, Hashable, Sendable {
    case you, launch, quickCapture, menuBar, appearance, avatars, colors, conversation, readAloud, dictation, location, webImages,
         sidebar, notifications, keyboardShortcuts, device, storage, spotlight, tips, help
}

/// Where Pincer Settings is shown: a tabbed window on the Mac, a list of pages on iPad and iPhone.
public enum AppSettingsPlatform: Hashable, Sendable, CaseIterable {
    case mac, pad, phone
}

/// A tab (macOS) or page (iOS) of Pincer Settings. Both platforms share these, in this order.
public enum AppSettingsPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, appearance, chats, notifications, privacy, shortcuts

    public var id: String { self.rawValue }

    public var title: String {
        switch self {
        case .general: L("General")
        case .appearance: L("Appearance")
        case .chats: L("Chats")
        case .notifications: L("Notifications")
        case .privacy: L("Privacy")
        case .shortcuts: L("Keyboard Shortcuts")
        }
    }

    /// The macOS tab label: short enough that six tabs fit the Settings window.
    public var tabTitle: String {
        self == .shortcuts ? L("Shortcuts") : self.title
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .chats: "bubble.left.and.text.bubble.right"
        case .notifications: "bell.badge"
        case .privacy: "hand.raised"
        case .shortcuts: "keyboard"
        }
    }

    /// The pages on a platform. iPhone has no hardware-keyboard commands to rebind.
    public static func pages(on platform: AppSettingsPlatform) -> [Self] {
        platform == .phone ? Self.allCases.filter { $0 != .shortcuts } : Self.allCases
    }

    /// The page's sections on a platform, in order. Every section a platform has is on exactly one page.
    public func sections(on platform: AppSettingsPlatform) -> [AppSettingsSection] {
        let all: [AppSettingsSection] = switch self {
        case .general: [.you, .launch, .quickCapture, .menuBar, .device, .storage, .spotlight, .tips, .help]
        case .appearance: [.appearance, .avatars, .colors, .sidebar]
        case .chats: [.conversation, .readAloud, .dictation]
        case .notifications: [.notifications]
        case .privacy: [.location, .webImages]
        case .shortcuts: [.keyboardShortcuts]
        }
        return all.filter { Self.sections(on: platform).contains($0) }
    }

    /// Every section that exists on a platform. Launch at login, Quick Capture and the menu bar are Mac only.
    public static func sections(on platform: AppSettingsPlatform) -> Set<AppSettingsSection> {
        var sections = Set(AppSettingsSection.allCases)
        if platform != .mac { sections.subtract([.launch, .quickCapture, .menuBar]) }
        if platform == .phone { sections.remove(.keyboardShortcuts) }
        return sections
    }
}

/// A request to show Pincer Settings, optionally at a page. Each request is new, so it never sticks.
public struct AppSettingsRoute: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let page: AppSettingsPage?

    public init(page: AppSettingsPage? = nil) {
        self.page = page
    }
}

extension AppModel {
    /// macOS: the Settings window reads this once to pick its tab, then clears it.
    public func takePendingAppSettingsPage() -> AppSettingsPage? {
        defer { self.pendingAppSettingsPage = nil }
        return self.pendingAppSettingsPage
    }
}
