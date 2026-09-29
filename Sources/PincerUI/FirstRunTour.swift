#if DEBUG
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A development tour of the first-run wizard (#175), for reviewing every screen: drives
/// `AppModel.shared.firstRun` the way the buttons do and saves the window as a PNG after each step.
/// Needs a fresh app (no gateways) and a fresh mock Gateway (token dev-token, MOCK_PAIRING=auto).
/// macOS: `PincerMacDev --first-run-screens <dir> [url]`. iOS (Debug): launch with the environment
/// variable `PINCER_FIRST_RUN_TOUR=<url>`; the PNGs go to the app's Documents/first-run-screens.
/// Removes the gateway it added when done.
@MainActor
public enum FirstRunTour {
    /// Toggles Find's Advanced… sheet.
    static let showAdvanced = Notification.Name("FirstRunTour.showAdvanced")

    /// iOS: starts the tour if the app was launched with `PINCER_FIRST_RUN_TOUR`.
    public static func startIfRequested() {
        guard let url = ProcessInfo.processInfo.environment["PINCER_FIRST_RUN_TOUR"] else { return }
        let directory = URL.documentsDirectory.appending(path: "first-run-screens")
        Task { @MainActor in
            let code = await self.run(to: directory, gatewayURL: url)
            print("first-run tour finished: \(code)")
        }
    }

    public static func run(to directory: URL, gatewayURL: String) async -> Int32 {
        let app = AppModel.shared
        let model = app.firstRun
        #if os(macOS)
        // Launched from a script the window may not open on its own: File › New Window.
        if !(await self.until(3, { self.hasWindow })) { self.newWindow() }
        #endif
        guard await self.until(20, { self.hasWindow }) else { return self.fail("No main window.") }
        guard app.gateways.isEmpty else { return self.fail("Start with no Gateways.") }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        self.mainWindow?.setContentSize(NSSize(width: 920, height: 660))
        // Key and active, so prominent buttons draw in the accent color as they do in use.
        self.activate()
        #endif
        var number = 0
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(700))
            #if os(macOS)
            if let window = self.mainWindow, !window.isKeyWindow, window.attachedSheet == nil {
                self.activate()
                try? await Task.sleep(for: .milliseconds(400))
            }
            #endif
            number += 1
            self.write(String(format: "%02d-%@.png", number, name), to: directory)
        }

        await snap("welcome")
        model.send(.getStarted)
        await snap("have-gateway")
        model.send(.answerHaveGateway(false))
        await snap("install")
        model.send(.installed)
        await snap(FirstRunModel.isMacOS ? "find-this-mac" : "find")
        model.send(.setLocation(.tailscale))
        model.send(.setAddress("my-mac.tail1234.ts.net"))
        await snap("find-tailscale")
        NotificationCenter.default.post(name: self.showAdvanced, object: nil)
        await snap("find-advanced")
        NotificationCenter.default.post(name: self.showAdvanced, object: nil)
        try? await Task.sleep(for: .milliseconds(600))
        model.send(.setLocation(.sameNetwork))
        model.send(.setAddress("ws://203.0.113.9:18789"))
        model.send(.checkAddress)
        await snap("find-insecure")
        model.send(.setAddress("127.0.0.1:9"))
        model.send(.checkAddress)
        _ = await self.until(10) { !model.state.reachability.isChecking }
        await snap("find-unreachable")
        model.send(.setAddress(gatewayURL))
        model.send(.checkAddress)
        guard await self.until(10, { model.state.step == .signIn }) else { return self.fail("Mock not reachable at \(gatewayURL).") }
        await snap("sign-in")
        model.send(.setAuthMode(.password))
        await snap("sign-in-password")
        model.send(.setAuthMode(.token))
        model.secret = "wrong-token"
        model.send(.signIn(hasSecret: true))
        _ = await self.until(10) { model.state.signInStatus.error != nil }
        await snap("sign-in-wrong-token")
        model.secret = "dev-token"
        model.send(.signIn(hasSecret: true))
        if await self.until(10, { if case .awaitingPairing = model.state.signInStatus { true } else { false } }) {
            await snap("approve-device")
        }
        guard await self.until(60, { model.state.step == .verify }) else { return self.fail("Sign-in didn't finish.") }
        model.send(.setName("Studio"))
        await snap("verify")

        model.send(.continueToSetup)
        guard let gateway = model.gateway else { return self.fail("The Gateway wasn't added.") }
        let setup = gateway.setup
        _ = await self.until(45) { gateway.state.isConnected && !setup.loadState.isRunning && setup.skills != nil }
        setup.currentStep = .agent
        await snap("setup-agent")
        setup.currentStep = .skills
        await snap("setup-skills")
        setup.currentStep = .testMessage
        await snap("setup-test-message")
        let sent = await gateway.sendSetupTestMessage(SetupWizardModel.testMessageText)
        if let key = sent.key {
            let chat = gateway.chat(for: key)
            _ = await self.until(20) {
                chat.entries.contains { if case let .assistant(turn) = $0 { !turn.isStreaming && !turn.body.isEmpty } else { false } }
            }
        }
        await snap("setup-test-replied")
        // Finish, as the button does: the steps end and the Setup Test chat opens.
        let chatKey = setup.testChatKey
        setup.advance()
        if let chatKey { app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: chatKey)) }
        _ = await self.until(5) { !model.isPresented }
        try? await Task.sleep(for: .seconds(2))
        await snap("chats-setup-test")

        model.present()
        await snap("add-gateway-find")
        model.send(.cancel)

        app.remove(gateway.id)
        _ = await self.until(5) { model.state.step == .welcome }
        return 0
    }

    #if os(macOS)
    private static var hasWindow: Bool { self.mainWindow != nil }

    /// A tour launched from a script starts in the background; `activate()` alone is only a request.
    @available(macOS, deprecated: 14)
    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        self.mainWindow?.makeKeyAndOrderFront(nil)
    }

    private static var mainWindow: NSWindow? {
        let visible = NSApp.windows.filter { $0.isVisible && $0.frame.width > 400 }
        return visible.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? visible.first
    }

    private static func newWindow() {
        func find(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == "n", item.keyEquivalentModifierMask == [.command], item.action != nil { return (menu, index) }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let (menu, index) = find(in: main) else { return }
        menu.performActionForItem(at: index)
    }

    /// The window as it's composited on screen (with its sheet, if any) via `screencapture`, which
    /// also draws the transcript's text views; `cacheDisplay` when that's not allowed.
    private static func write(_ name: String, to directory: URL) {
        let url = directory.appending(path: name)
        if let window = self.mainWindow {
            let target = window.attachedSheet ?? window
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(target.windowNumber), url.path]
            if (try? process.run()) != nil {
                process.waitUntilExit()
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                    print("Wrote \(name)")
                    return
                }
            }
        }
        guard let view = self.mainWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: name))
        print("Wrote \(name)")
    }
    #else
    private static var hasWindow: Bool { self.window != nil }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    }

    private static func write(_ name: String, to directory: URL) {
        guard let window = self.window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: directory.appending(path: name))
        print("Wrote \(name)")
    }
    #endif

    private static func until(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func fail(_ message: String) -> Int32 {
        print("first-run screens: \(message)")
        return 1
    }
}
#endif
