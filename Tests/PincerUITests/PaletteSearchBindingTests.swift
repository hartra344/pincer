#if DEBUG && os(iOS)
import Foundation
import SwiftUI
import UIKit
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor private final class PaletteIDsCapture { var latest: [String]? }
@MainActor @Suite(.timeLimit(.minutes(2))) struct PaletteSearchBindingTests {
    @Test func actualNativeQueryBindingRunsShippedRanking() async throws {
        let scratch = ScratchDefaults(), app = AppModel(defaults: scratch.defaults)
        defer { scratch.remove() }
        let probe = PaletteSearchProbe(), capture = PaletteIDsCapture()
        let view = CommandPaletteView(isPresented: .constant(true))
            .environment(app).defaultAppStorage(scratch.defaults)
            .environment(\.paletteSearchProbe, probe)
            .environment(\.paletteRankedIDsObserver, { capture.latest = $0 })
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
        try #require(await eventually(timeout: .seconds(15)) {
            window.layoutIfNeeded()
            return capture.latest?.isEmpty == false && views(window).contains { $0 is UITextField }
        }, "actual ordinary palette rows must exist before query admission")
        let field = try #require(views(window).compactMap { $0 as? UITextField }.first)
        try #require(field.isEnabled && field.window != nil)
        field.text = "unmatchedpalettequery"
        var invoked = 0
        for target in field.allTargets {
            guard let object = target.base as? NSObject else { continue }
            for action in field.actions(forTarget: object, forControlEvent: .editingChanged) ?? [] {
                let selector = NSSelectorFromString(action)
                guard object.responds(to: selector) else { continue }
                object.perform(selector, with: field); invoked += 1
            }
        }
        try #require(invoked > 0, "actual native query binding action must run")
        try #require(await eventually(timeout: .seconds(15)) { capture.latest == [] }, "actual edited query must change shipped result IDs")
        let counts = probe.counts
        #expect(counts.main == [0, 0, 0] && counts.worker.allSatisfy { $0 > 0 })
    }
}
@MainActor extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func actualCommandPaletteFieldUsesOffMainRanking() async throws {
        try await PaletteSearchBindingTests().actualNativeQueryBindingRunsShippedRanking()
    }
}
#endif
