import Foundation

/// User preferences for Markdown-aware composer editing.
public struct ComposerMarkdownSettings {
    public static let liveStylingKey = "pincer.composer.markdownStyling"
    public static let formatBarKey = "pincer.composer.formatBar"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Dim markers and style Markdown live in the composer. On unless the user turned it off.
    public var liveStyling: Bool {
        get { self.defaults.object(forKey: Self.liveStylingKey) as? Bool ?? true }
        nonmutating set { self.defaults.set(newValue, forKey: Self.liveStylingKey) }
    }

    /// iOS formatting bar above the keyboard. Off unless the user turned it on.
    public var showsFormatBar: Bool {
        get { self.defaults.object(forKey: Self.formatBarKey) as? Bool ?? false }
        nonmutating set { self.defaults.set(newValue, forKey: Self.formatBarKey) }
    }
}
