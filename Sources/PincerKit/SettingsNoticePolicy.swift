import Foundation

/// Severity for transient messages shown by Gateway Settings pages.
public enum SettingsNoticeSeverity: Equatable, Sendable {
    case success
    case info
    case warning
    case error
}

/// A transient message a Gateway Settings model shows on its page.
public struct SettingsNotice: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let severity: SettingsNoticeSeverity

    public init(text: String, severity: SettingsNoticeSeverity = .info) {
        self.text = text
        self.severity = severity
    }
}

/// Shared lifetime rule for settings notices. The UI owns the timer; this policy only decides
/// whether the severity is eligible for automatic dismissal.
public enum SettingsNoticePolicy {
    public static func shouldAutoDismiss(_ severity: SettingsNoticeSeverity) -> Bool {
        switch severity {
        case .success, .info: true
        case .warning, .error: false
        }
    }
}
