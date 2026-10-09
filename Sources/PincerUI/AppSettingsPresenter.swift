import PincerKit
import SwiftUI

extension AppSettingsPlatform {
    @MainActor static var current: Self {
        #if os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }
}

/// Opens Pincer Settings, optionally at a page: the Settings window on macOS, a sheet on iOS.
/// `gateway` opens Gateways with that Gateway selected for editing.
struct AppSettingsOpener {
    var open: @MainActor (AppSettingsRoute) -> Void = { _ in }

    @MainActor
    func callAsFunction(_ page: AppSettingsPage? = nil, gateway: UUID? = nil) {
        self.open(AppSettingsRoute(page: page, gatewayId: gateway))
    }
}

extension EnvironmentValues {
    @Entry var openAppSettings = AppSettingsOpener()
}

/// The one place a scene presents Pincer Settings. Every entry point (the iOS gear, the command
/// palette, links to a page) goes through `\.openAppSettings`, so there's one sheet per scene.
struct AppSettingsPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @State private var route: AppSettingsRoute?
    @State private var afterDismiss: (@MainActor () -> Void)?
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.environment(\.openAppSettings, AppSettingsOpener { route in
            self.app.pendingAppSettingsGatewayId = route.gatewayId
            self.app.pendingAppSettingsPage = route.page
            self.openSettings()
        })
        #else
        content
            .environment(\.openAppSettings, AppSettingsOpener { route in
                self.app.pendingAppSettingsGatewayId = route.gatewayId
                self.route = route
            })
            .sheet(item: self.$route, onDismiss: self.runAfterDismiss) { route in
                AppSettingsSheet(initialPage: route.page) { self.route = nil }
                    .environment(\.closeAppSettings, CloseAppSettings { action in
                        self.afterDismiss = action
                        self.route = nil
                    })
            }
        #endif
    }

    #if os(iOS)
    private func runAfterDismiss() {
        let action = self.afterDismiss
        self.afterDismiss = nil
        action?()
    }
    #endif
}

/// Closes Pincer Settings, then runs `action`: on iOS once the sheet is gone, so a wizard or
/// another sheet can show; on macOS the Settings window stays and `action` runs at once.
struct CloseAppSettings {
    var close: @MainActor (@escaping @MainActor () -> Void) -> Void = { $0() }

    @MainActor
    func callAsFunction(then action: @escaping @MainActor () -> Void) {
        self.close(action)
    }
}

extension EnvironmentValues {
    @Entry var closeAppSettings = CloseAppSettings()
}

#if os(iOS)
/// iOS: the list of Settings pages, opened at a page when asked. Builds only the list until a page is pushed.
struct AppSettingsSheet: View {
    let close: () -> Void
    @State private var path: [AppSettingsPage]

    init(initialPage: AppSettingsPage?, close: @escaping () -> Void) {
        self.close = close
        self._path = State(initialValue: initialPage.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: self.$path) {
            SettingsView(close: self.close)
        }
    }
}
#endif
