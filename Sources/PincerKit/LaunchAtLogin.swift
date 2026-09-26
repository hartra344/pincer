import Foundation

/// Where the app's login item stands, mirroring `SMAppService.Status` without importing
/// ServiceManagement, so the mapping to UI can be tested on every platform.
public enum LoginItemStatus: Sendable, CaseIterable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// Which change to the login item last failed.
public enum LoginItemFailure: Sendable {
    case register, unregister
}

/// Copy for Settings → General → Launch.
public enum LaunchAtLogin {
    public static let approvalFooter =
        "Allow Pincer in System Settings → General → Login Items & Extensions to finish turning this on."
    public static let registerErrorFooter =
        "Couldn't turn on Open at Login. Try again, or add Pincer in System Settings → General → Login Items & Extensions."
    public static let unregisterErrorFooter =
        "Couldn't turn off Open at Login. Remove Pincer in System Settings → General → Login Items & Extensions."
}

/// What the Open at Login toggle and its footer show for a status and the last failure.
public struct LoginItemPresentation: Equatable, Sendable {
    public let isOn: Bool
    public let footer: String?
    public let footerIsError: Bool
    public let showsSettingsButton: Bool

    public init(status: LoginItemStatus, failure: LoginItemFailure?) {
        self.isOn = status == .enabled || status == .requiresApproval
        switch (failure, status) {
        case (.register?, _):
            self.footer = LaunchAtLogin.registerErrorFooter
            self.footerIsError = true
            self.showsSettingsButton = true
        case (.unregister?, _):
            self.footer = LaunchAtLogin.unregisterErrorFooter
            self.footerIsError = true
            self.showsSettingsButton = true
        case (nil, .requiresApproval):
            self.footer = LaunchAtLogin.approvalFooter
            self.footerIsError = false
            self.showsSettingsButton = true
        case (nil, _):
            self.footer = nil
            self.footerIsError = false
            self.showsSettingsButton = false
        }
    }
}
