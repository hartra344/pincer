import Foundation
import Testing
@testable import PincerKit

/// #955: Pincer Settings shares one page layout across Mac, iPad and iPhone.
@Suite("App settings layout")
struct AppSettingsLayoutTests {
    @Test(arguments: AppSettingsPlatform.allCases)
    func everySectionIsOnExactlyOnePage(platform: AppSettingsPlatform) {
        let pages = AppSettingsPage.pages(on: platform)
        let available = AppSettingsPage.sections(on: platform)
        for section in available {
            let owners = pages.filter { $0.sections(on: platform).contains(section) }
            #expect(owners.count == 1, "\(section) is on \(owners) on \(platform)")
        }
        for page in pages {
            let sections = page.sections(on: platform)
            #expect(!sections.isEmpty, "\(page) is empty on \(platform)")
            #expect(Set(sections).isSubset(of: available), "\(page) lists sections \(platform) lacks")
            #expect(Set(sections).count == sections.count, "\(page) repeats a section on \(platform)")
        }
        #expect(Set(pages.flatMap { $0.sections(on: platform) }) == available)
    }

    @Test func platformSpecificSections() {
        let mac = AppSettingsPage.sections(on: .mac)
        #expect(mac == Set(AppSettingsSection.allCases))
        for platform in [AppSettingsPlatform.pad, .phone] {
            let sections = AppSettingsPage.sections(on: platform)
            #expect(sections.isDisjoint(with: [.launch, .quickCapture, .menuBar]), "\(platform) has Mac-only sections")
        }
        #expect(AppSettingsPage.sections(on: .pad).contains(.keyboardShortcuts))
        #expect(!AppSettingsPage.sections(on: .phone).contains(.keyboardShortcuts))
        #expect(!AppSettingsPage.pages(on: .phone).contains(.shortcuts))
        #expect(AppSettingsPage.pages(on: .pad).contains(.shortcuts))
        #expect(AppSettingsPage.pages(on: .mac).contains(.shortcuts))
    }

    @Test func pageOrderAndIdentity() {
        #expect(AppSettingsPage.allCases == [.general, .appearance, .chats, .notifications, .privacy, .shortcuts])
        #expect(AppSettingsPage.pages(on: .mac) == AppSettingsPage.allCases)
        #expect(AppSettingsPage.pages(on: .phone) == [.general, .appearance, .chats, .notifications, .privacy])
        #expect(AppSettingsPage.allCases.map(\.rawValue)
            == ["general", "appearance", "chats", "notifications", "privacy", "shortcuts"])
        #expect(AppSettingsPage.allCases.allSatisfy { $0.id == $0.rawValue })
        let titles = AppSettingsPage.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
        #expect(AppSettingsPage.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }

    @Test(arguments: AppSettingsPlatform.allCases)
    func sectionsLiveOnTheirPages(platform: AppSettingsPlatform) {
        #expect(AppSettingsPage.appearance.sections(on: platform).contains(.sidebar))
        #expect(AppSettingsPage.privacy.sections(on: platform) == [.location, .webImages])
        #expect(AppSettingsPage.chats.sections(on: platform) == [.conversation, .readAloud, .dictation])
        #expect(AppSettingsPage.notifications.sections(on: platform) == [.notifications])
    }

    @Test func eachRouteIsANewRequest() {
        let first = AppSettingsRoute(page: .chats)
        let second = AppSettingsRoute(page: .chats)
        #expect(first.page == second.page)
        #expect(first.id != second.id)
        #expect(first != second)
        #expect(AppSettingsRoute().page == nil)
    }

    @MainActor
    @Test func pendingPageIsOneShot() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        #expect(app.takePendingAppSettingsPage() == nil)
        app.pendingAppSettingsPage = .privacy
        #expect(app.takePendingAppSettingsPage() == .privacy)
        #expect(app.pendingAppSettingsPage == nil)
        #expect(app.takePendingAppSettingsPage() == nil)
    }
}
