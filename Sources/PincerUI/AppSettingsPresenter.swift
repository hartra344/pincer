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
struct AppSettingsOpener {
    var open: @MainActor (AppSettingsPage?) -> Void = { _ in }

    @MainActor
    func callAsFunction(_ page: AppSettingsPage? = nil) {
        self.open(page)
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
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.environment(\.openAppSettings, AppSettingsOpener { page in
            self.app.pendingAppSettingsPage = page
            self.openSettings()
        })
        #else
        content
            .environment(\.openAppSettings, AppSettingsOpener { page in
                self.route = AppSettingsRoute(page: page)
            })
            .sheet(item: self.$route) { route in
                AppSettingsSheet(initialPage: route.page) { self.route = nil }
            }
        #endif
    }
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
