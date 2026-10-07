#if os(iOS)
import Foundation
import QuickLook
import SwiftUI
import Testing
import UIKit
@testable import PincerUI
@testable import PincerKit

@MainActor @Observable private final class QuickLookFixtureState {
    var url: URL?
    var visible = true
}
private struct ActualQuickLookFixture: View {
    let state: QuickLookFixtureState
    var body: some View {
        @Bindable var state = state
        if state.visible {
            Text("Preview fixture").modifier(ChatQuickLookLifecycle(url: $state.url))
        }
    }
}
@MainActor extension TranscriptUIKitHostedTests {
    // The SwiftPM package process has no app scene; this is an explicit app-hosted probe.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PINCER_QUICKLOOK_APP_HOSTED"] == "1"), .timeLimit(.minutes(2)))
    func actualQuickLookPresentationRetainsFileUntilDismissal() async throws {
        let root = FilePreviewFiles.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("Preview.txt")
        let state = QuickLookFixtureState()
        let host = UIHostingController(rootView: ActualQuickLookFixture(state: state))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(scenes.first { $0.activationState == .foregroundActive }, "An actual active app UIWindowScene is required")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        var stage = 0
        func dismiss(_ controller: UIViewController) async -> Bool {
            var completed = false
            controller.dismiss(animated: false) { completed = true }
            return await eventually(timeout: .seconds(15)) { completed }
        }
        do {
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("Actual local Quick Look text preview.".utf8).write(to: file)
        }.value
            try #require(await eventually(timeout: .seconds(15)) { window.layoutIfNeeded(); return host.view.window != nil })
            stage = 1
            state.url = file
            func preview(_ controller: UIViewController) -> QLPreviewController? {
                if let value = controller as? QLPreviewController { return value }
                if let presented = controller.presentedViewController, let found = preview(presented) { return found }
                for child in controller.children { if let found = preview(child) { return found } }
                return nil
            }
            try #require(await eventually(timeout: .seconds(15)) { { guard let ql = preview(host) else { return false }; return ql.viewIfLoaded?.window != nil && !ql.isBeingPresented && ql.transitionCoordinator == nil }() },
                         "The actual public Quick Look modifier must present a real QLPreviewController")
            stage = 2
            #expect(state.url == file, "Opening Quick Look must not clear its owner binding")
            let existsWhileOpen = await Task.detached { FileManager.default.fileExists(atPath: file.path) }.value
            #expect(existsWhileOpen, "Backing file survives actual presentation")
            let presented = try #require(host.presentedViewController)
            try #require(await dismiss(presented), "Actual public dismissal completion must finish within its bound")
            stage = 3
            try #require(await eventually(timeout: .seconds(15)) { host.presentedViewController == nil })
            // Dismissal alone must retire the actual binding and backing file.
            try #require(await eventually(timeout: .seconds(15)) { state.url == nil })
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while await Task.detached(operation: { FileManager.default.fileExists(atPath: file.path) }).value {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            print("QUICKLOOK_LIFECYCLE stage=\(stage) current=\(state.url != nil) scenes=\(scenes.count)")
            if let presented = host.presentedViewController { _ = await dismiss(presented) }
            window.isHidden = true
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        window.isHidden = true
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
#endif
