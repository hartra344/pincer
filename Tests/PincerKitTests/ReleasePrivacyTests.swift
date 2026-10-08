import Foundation
import Testing
@testable import PincerKit

@Suite("Release privacy resources")
struct ReleasePrivacyTests {
    @Test func privacyManifestIsInTheCompiledKitResourceBundle() throws {
        let url = try #require(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        let entries = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let defaults = try #require(entries.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" })
        #expect(Set(defaults["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []) == ["CA92.1", "1C8F.1"])
        #expect(entries.contains { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp" })
        #expect(entries.contains { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategorySystemBootTime" })
    }

    @Test func publicLinksDoNotCarryCredentialsOrUserContext() {
        for url in [AppLinks.privacy, AppLinks.support] {
            #expect(url.scheme == "https")
            #expect(url.host == "www.pincerchat.dev")
            #expect(url.user == nil && url.password == nil && url.query == nil && url.fragment == nil)
        }
    }
}
