import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func runOpenAtLoginChecks() {
    do {
        let failures: [LoginItemFailure?] = [nil, .register, .unregister]
        for status in LoginItemStatus.allCases {
            for failure in failures {
                let shown = LoginItemPresentation(status: status, failure: failure)
                let on = status == .enabled || status == .requiresApproval
                let footer: String? = switch (failure, status) {
                case (.register?, _): LaunchAtLogin.registerErrorFooter
                case (.unregister?, _): LaunchAtLogin.unregisterErrorFooter
                case (nil, .requiresApproval): LaunchAtLogin.approvalFooter
                case (nil, _): nil
                }
                check(shown.isOn == on && shown.footer == footer && shown.footerIsError == (failure != nil)
                      && shown.showsSettingsButton == (footer != nil),
                      "\(status) with failure \(failure.map { "\($0)" } ?? "none") maps to the right toggle and footer")
            }
        }
        check([LaunchAtLogin.approvalFooter, LaunchAtLogin.registerErrorFooter, LaunchAtLogin.unregisterErrorFooter]
              .allSatisfy { $0.contains("Login Items") }, "every footer points at Login Items")
    }
}
