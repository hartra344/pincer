import Testing
@testable import PincerKit

@Suite("Open at Login presentation")
struct LaunchAtLoginTests {
    @Test(arguments: LoginItemStatus.allCases)
    func withoutFailure(status: LoginItemStatus) {
        let shown = LoginItemPresentation(status: status, failure: nil)
        #expect(shown.isOn == (status == .enabled || status == .requiresApproval))
        #expect(!shown.footerIsError)
        if status == .requiresApproval {
            #expect(shown.footer == LaunchAtLogin.approvalFooter)
            #expect(shown.showsSettingsButton)
        } else {
            #expect(shown.footer == nil)
            #expect(!shown.showsSettingsButton)
        }
    }

    @Test(arguments: LoginItemStatus.allCases, [LoginItemFailure.register, .unregister])
    func withFailure(status: LoginItemStatus, failure: LoginItemFailure) {
        let shown = LoginItemPresentation(status: status, failure: failure)
        #expect(shown.isOn == (status == .enabled || status == .requiresApproval))
        #expect(shown.footer == (failure == .register ? LaunchAtLogin.registerErrorFooter : LaunchAtLogin.unregisterErrorFooter))
        #expect(shown.footerIsError)
        #expect(shown.showsSettingsButton)
    }

    @Test func copyPointsAtLoginItems() {
        let copy = [LaunchAtLogin.approvalFooter, LaunchAtLogin.registerErrorFooter, LaunchAtLogin.unregisterErrorFooter]
        #expect(Set(copy).count == copy.count)
        for text in copy {
            #expect(!text.isEmpty)
            #expect(text.contains("Login Items"))
        }
    }
}
