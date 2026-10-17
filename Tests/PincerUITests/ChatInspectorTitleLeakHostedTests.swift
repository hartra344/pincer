#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

/// #1026: opening and closing the Browser panel must not leave "Browser" in the chat's navigation item.
@MainActor
@Observable
private final class InspectorPanelDriver {
    var panel: ChatInspectorPanel?
}

/// Captures the real ChatChrome's panel binding so the test can open and close the workspace panel.
@MainActor
private struct ActionsCapture: View {
    @Environment(\.chatChromeActions) private var actions
    let sink: (ChatChromeActions) -> Void
    var body: some View { Color.clear.frame(width: 1, height: 1).onAppear { if let actions = self.actions { self.sink(actions) } } }
}

@MainActor
private struct RealChromeHost: View {
    let app: AppModel
    let gateway: GatewayStore
    let sizeClass: UserInterfaceSizeClass
    let sink: (ChatChromeActions) -> Void

    var body: some View {
        NavigationStack {
            if let key = self.gateway.selectedKey {
                ChatView(chat: self.gateway.chat(for: key))
                    .overlay(alignment: .topLeading) { ActionsCapture(sink: self.sink) }
                    .modifier(ChatChrome())
            }
        }
        .environment(self.app)
        .environment(self.gateway)
        .defaultAppStorage(self.gateway.defaults)
        .environment(\.horizontalSizeClass, self.sizeClass)
    }
}

@MainActor
private struct InspectorTitleHost: View {
    let driver: InspectorPanelDriver
    let app: AppModel
    let gateway: GatewayStore
    let sizeClass: UserInterfaceSizeClass

    var body: some View {
        NavigationStack {
            Text("Chat body")
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .modifier(ChatInspectorChrome(panel: Binding(get: { self.driver.panel }, set: { self.driver.panel = $0 })))
        }
        .environment(self.app)
        .environment(self.gateway)
        .defaultAppStorage(self.gateway.defaults)
        .environment(\.horizontalSizeClass, self.sizeClass)
    }
}

@MainActor
private struct ChatInspectorTitleLeakTests {
    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(self.controllers)
    }

    /// Titles of every navigation item on the window's own (non-presented) navigation stack.
    private func chatTitles(_ root: UIViewController) -> [String] {
        self.controllers(root).compactMap { $0 as? UINavigationController }
            .flatMap(\.viewControllers).compactMap { $0.navigationItem.title }
    }

    /// Lets pending SwiftUI/UIKit updates run: a bounded number of layout passes, each after a main-actor yield.
    private func settle(_ window: UIWindow) async {
        for _ in 0..<20 {
            await Task.yield()
            window.layoutIfNeeded()
        }
    }

    /// Text of every label/accessibility label in the window, to catch a title drawn in the bar's views.
    private func labels(_ root: UIView) -> [String] {
        let own = [(root as? UILabel)?.text, root.accessibilityLabel].compactMap { $0 }
        return own + root.subviews.flatMap(self.labels)
    }

    func run(_ sizeClass: UserInterfaceSizeClass, realChrome: Bool = false) async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        let gateway = app.add(.demo(), secret: nil)
        gateway.cacheRoot = nil
        gateway.notifier = nil
        defer { app.remove(gateway.id); scratch.remove() }
        let connected = await eventually(timeout: .seconds(30)) { gateway.state.isConnected }
        try #require(connected)

        let driver = InspectorPanelDriver()
        var captured: ChatChromeActions?
        let controller: UIViewController
        if realChrome {
            let ready = await eventually(timeout: .seconds(30)) { gateway.sessions["agent:main:dashboard:trip"] != nil }
            try #require(ready)
            gateway.selectedKey = "agent:main:dashboard:trip"
            controller = UIHostingController(rootView: RealChromeHost(app: app, gateway: gateway, sizeClass: sizeClass) { captured = $0 })
        } else {
            controller = UIHostingController(rootView: InspectorTitleHost(driver: driver, app: app, gateway: gateway, sizeClass: sizeClass))
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState != .unattached }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: sizeClass == .compact ? 390 : 1024, height: 844)
        window.rootViewController = controller
        let previous = scene?.windows.first(where: { $0.isKeyWindow })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }

        let installed = await eventually(timeout: .seconds(15)) {
            window.layoutIfNeeded()
            return self.controllers(controller).contains { $0 is UINavigationController }
        }
        try #require(installed)

        if realChrome {
            _ = await eventually(timeout: .seconds(10)) { captured != nil }
            try #require(captured != nil)
            captured?.showWorkspace.wrappedValue = true
        } else { driver.panel = .workspace }
        // The compact sheet reports its presentation; the inspector has no UIKit signal, so let layout settle.
        if sizeClass == .compact {
            let presented = await eventually(timeout: .seconds(10)) { controller.presentedViewController != nil }
            try #require(presented)
        } else {
            await self.settle(window)
        }
        window.layoutIfNeeded()
        if realChrome, sizeClass == .compact, let sheet = controller.presentedViewController {
            // Like the sheet's Done button: UIKit dismisses, SwiftUI's binding follows.
            sheet.dismiss(animated: true)
        } else if realChrome { captured?.showWorkspace.wrappedValue = false } else { driver.panel = nil }
        if sizeClass == .compact {
            // Best effort: the hosted sheet may keep its controller around; the title check below is what matters.
            _ = await eventually(timeout: .seconds(5)) { controller.presentedViewController == nil }
        }
        await self.settle(window)

        let titles = self.chatTitles(controller) + self.labels(window).filter { $0 == "Browser" }
        #expect(!titles.contains("Browser"),
                "closing the Browser panel (\(sizeClass == .compact ? "compact sheet" : "regular inspector")) left the chat title as \(titles)")
    }
}

@MainActor
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)))
    func browserPanelCloseDoesNotLeaveTitleCompact() async throws {
        try await ChatInspectorTitleLeakTests().run(.compact)
    }

    @Test(.timeLimit(.minutes(2)))
    func browserPanelCloseKeepsChatTitleCompactRealChrome() async throws {
        try await ChatInspectorTitleLeakTests().run(.compact, realChrome: true)
    }

    @Test(.timeLimit(.minutes(2)))
    func browserPanelCloseKeepsChatTitleRegularRealChrome() async throws {
        try await ChatInspectorTitleLeakTests().run(.regular, realChrome: true)
    }

    @Test(.timeLimit(.minutes(2)))
    func browserPanelCloseDoesNotLeaveTitleRegular() async throws {
        try await ChatInspectorTitleLeakTests().run(.regular)
    }
}
#endif
