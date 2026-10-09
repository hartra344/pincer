import Foundation
@testable import PincerKit

/// Offline (#955): Pincer Settings pages cover every section once per platform, and a route is one-shot.
@MainActor
func runAppSettingsLayoutChecks() {
    for platform in AppSettingsPlatform.allCases {
        let pages = AppSettingsPage.pages(on: platform)
        let available = AppSettingsPage.sections(on: platform)
        check(available.allSatisfy { section in pages.filter { $0.sections(on: platform).contains(section) }.count == 1 },
              "app settings: every \(platform) section is on exactly one page")
        check(pages.allSatisfy { !$0.sections(on: platform).isEmpty && Set($0.sections(on: platform)).isSubset(of: available) },
              "app settings: no \(platform) page is empty or lists a missing section")
    }
    check(AppSettingsPage.sections(on: .mac).isSuperset(of: [.launch, .quickCapture, .menuBar])
          && AppSettingsPage.sections(on: .pad).isDisjoint(with: [.launch, .quickCapture, .menuBar])
          && AppSettingsPage.sections(on: .phone).isDisjoint(with: [.launch, .quickCapture, .menuBar]),
          "app settings: launch, Quick Capture and menu bar are Mac only")
    check(!AppSettingsPage.sections(on: .phone).contains(.keyboardShortcuts) && !AppSettingsPage.pages(on: .phone).contains(.shortcuts)
          && AppSettingsPage.pages(on: .pad).contains(.shortcuts), "app settings: iPhone has no Keyboard Shortcuts page")
    check(AppSettingsPage.allCases == [.general, .appearance, .chats, .notifications, .privacy, .shortcuts],
          "app settings: page order")
    check(AppSettingsPage.appearance.sections(on: .mac).contains(.sidebar)
          && AppSettingsPage.privacy.sections(on: .phone) == [.location, .webImages]
          && AppSettingsPage.chats.sections(on: .pad) == [.conversation, .readAloud, .dictation],
          "app settings: Sidebar on Appearance, Location on Privacy, voice on Chats")

    let first = AppSettingsRoute(page: .chats), second = AppSettingsRoute(page: .chats)
    check(first.id != second.id, "app settings: two equal-page routes are distinct requests")
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let app = AppModel(defaults: defaults)
    app.pendingAppSettingsPage = .notifications
    check(app.takePendingAppSettingsPage() == .notifications && app.pendingAppSettingsPage == nil
          && app.takePendingAppSettingsPage() == nil, "app settings: the pending tab is taken once")
}
