#if os(macOS)
import AppKit
import os
import PincerKit
import ServiceManagement
import SwiftUI

/// Registers Pincer as a login item through `SMAppService.mainApp`.
@MainActor @Observable
final class LaunchAtLoginController {
    private(set) var status: LoginItemStatus = .notRegistered
    private(set) var failure: LoginItemFailure?

    @ObservationIgnored private let logger = Logger(subsystem: "chat.pincer", category: "LaunchAtLogin")

    var presentation: LoginItemPresentation {
        LoginItemPresentation(status: self.status, failure: self.failure)
    }

    /// Re-reads the system status. Clears a stale failure: called on appear and when the app
    /// becomes active (e.g. back from System Settings), never right after a failed change.
    func refresh() {
        self.failure = nil
        self.readStatus()
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            self.failure = nil
        } catch {
            self.failure = on ? .register : .unregister
            self.logger.error("Login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        self.readStatus()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func readStatus() {
        switch SMAppService.mainApp.status {
        case .notRegistered: self.status = .notRegistered
        case .enabled: self.status = .enabled
        case .requiresApproval: self.status = .requiresApproval
        case .notFound: self.status = .notFound
        @unknown default: self.status = .notRegistered
        }
    }
}

/// Settings → General → Launch: open Pincer at login so Quick Capture is ready.
struct LaunchAtLoginSettingsSection: View {
    @State private var controller = LaunchAtLoginController()

    var body: some View {
        let presentation = self.controller.presentation
        Section {
            Toggle(isOn: Binding(get: { presentation.isOn }, set: { self.controller.setEnabled($0) })) {
                Text("Open at Login")
                Text("Start Pincer when you log in, so Quick Capture is ready.")
            }
            if presentation.showsSettingsButton {
                Button("Open Login Items Settings…") { self.controller.openSystemSettings() }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text("Launch")
        } footer: {
            if let footer = presentation.footer {
                Text(footer).foregroundStyle(presentation.footerIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
        .onAppear { self.controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.controller.refresh()
        }
    }
}
#endif
