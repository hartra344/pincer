import Foundation

/// Severity for transient messages shown by Gateway Settings pages.
public enum SettingsNoticeSeverity: Equatable, Sendable {
    case success
    case info
    case warning
    case error
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
