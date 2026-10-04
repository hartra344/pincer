#if os(iOS) && DEBUG
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite("Actual Tools Inspector query binding", .timeLimit(.minutes(2)))
struct ToolsInspectorSearchBindingTests {
    @Test func actualEditableFieldPublishesCurrentPreparedRows() async throws {
        let payload: JSONValue = ["agentId": "main", "profiles": [], "groups": [["id": "g", "label": "Group", "tools": [
            ["id": "one", "label": "One", "description": "first needle"],
            ["id": "two", "label": "Two", "description": "second needle"]]]]]
        let model = ToolsInspectorModel(scope: .agent("main", sessionKey: nil), methods: { ["tools.catalog"] }) { _, _ in payload }
        let host = UIHostingController(rootView: ToolsInspectorView(model: model, scopeTitle: "Fixture"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.isHidden = false
        defer { model.searchPreparation.invalidate(); window.isHidden = true; window.rootViewController = nil }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        try #require(await eventually(timeout: .seconds(15)) {
            window.layoutIfNeeded()
            return model.searchPreparation.result?.groups.flatMap(\.tools).count == 2
                && views(window).contains { $0 is UITextField }
        })
        let field = try #require(views(window).compactMap { $0 as? UITextField }.first)
        field.text = "second"
        var invoked = 0
        for target in field.allTargets {
            guard let object = target.base as? NSObject else { continue }
            for action in field.actions(forTarget: object, forControlEvent: .editingChanged) ?? [] {
                let selector = NSSelectorFromString(action)
                guard object.responds(to: selector) else { continue }
                object.perform(selector, with: field); invoked += 1
            }
        }
        try #require(invoked > 0, "actual SwiftUI field must expose its registered native query action")
        try #require(await eventually(timeout: .seconds(15)) {
            model.searchPreparation.result?.groups.flatMap(\.tools).map(\.id) == ["two"]
        }, "actual query binding must publish only its finished matching rows")
    }
}
// The existing CI selector includes TranscriptUIKitHostedTests.
@MainActor
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)))
    func actualToolsInspectorFieldUsesOffMainPreparedResults() async throws {
        try await ToolsInspectorSearchBindingTests().actualEditableFieldPublishesCurrentPreparedRows()
    }
}
#endif
