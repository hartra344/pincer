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
    @Test(.timeLimit(.minutes(2)))
    func actualQuickLookPresentationRetainsFileUntilDismissal() async throws {
        let root = FilePreviewFiles.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("Preview.txt")
        let state = QuickLookFixtureState()
        let host = UIHostingController(rootView: ActualQuickLookFixture(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.isHidden = false
        do {
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("Actual local Quick Look text preview.".utf8).write(to: file)
        }.value
            try #require(await eventually(timeout: .seconds(15)) { window.layoutIfNeeded(); return host.view.window != nil })
            state.url = file
            func preview(_ controller: UIViewController) -> QLPreviewController? {
                if let value = controller as? QLPreviewController { return value }
                if let presented = controller.presentedViewController, let found = preview(presented) { return found }
                for child in controller.children { if let found = preview(child) { return found } }
                return nil
            }
            try #require(await eventually(timeout: .seconds(15)) { { guard let ql = preview(host) else { return false }; return ql.viewIfLoaded?.window != nil && !ql.isBeingPresented && ql.transitionCoordinator == nil }() },
                         "The actual public Quick Look modifier must present a real QLPreviewController")
            #expect(state.url == file, "Opening Quick Look must not clear its owner binding")
            let existsWhileOpen = await Task.detached { FileManager.default.fileExists(atPath: file.path) }.value
            #expect(existsWhileOpen, "Backing file survives actual presentation")
            let presented = try #require(host.presentedViewController)
            await withCheckedContinuation { continuation in presented.dismiss(animated: false) { continuation.resume() } }
            try #require(await eventually(timeout: .seconds(15)) { host.presentedViewController == nil })
            // Dismissal alone must retire the actual binding and backing file.
            try #require(await eventually(timeout: .seconds(15)) { state.url == nil })
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while await Task.detached(operation: { FileManager.default.fileExists(atPath: file.path) }).value {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            if let presented = host.presentedViewController {
                await withCheckedContinuation { continuation in presented.dismiss(animated: false) { continuation.resume() } }
            }
            window.isHidden = true
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        window.isHidden = true
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
#endif
