#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class DictationTargetTestEngine: DictationEngine {
    private var onPartial: (@MainActor (String, Bool) -> Void)?
    private var onError: (@MainActor (DictationIssue) -> Void)?

    var isAvailable = true

    func authorize() async -> DictationIssue? { nil }

    func start(onPartial: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (DictationIssue) -> Void) throws {
        self.onPartial = onPartial
        self.onError = onError
    }

    func stop() {}
    func cancel() {
        self.onPartial = nil
        self.onError = nil
    }
}

@MainActor
@Observable
private final class DictationTargetDraft {
    var text = ""
}

@MainActor
private struct DictationTargetHost: View {
    let app: AppModel
    let model: DictationModel
    let sceneID: UUID
    let gatewayID: UUID
    let sessionKey: String
    @Bindable var draft: DictationTargetDraft
    var paneIsActive = true

    var body: some View {
        DictationButton(model: self.model, app: self.app, gatewayID: self.gatewayID, sessionKey: self.sessionKey,
                        draft: Binding(get: { self.draft.text }, set: { self.draft.text = $0 }),
                        selection: nil, onCaret: { _ in }, isFieldFocused: false, onRequestFocus: {})
            .frame(width: 160, height: 60)
            .environment(\.dictationSceneID, self.sceneID)
            .environment(\.chatPaneIsActive, self.paneIsActive)
    }
}

/// Two separate windows can show the same session key; a palette request must still choose one composer.
@MainActor
@Suite("Dictation target routing", .serialized)
struct DictationTargetHostedTests {
    @Test func sameSessionKeyInSeparateWindowsDoesNotStartBothComposers() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        let sessionKey = "agent:main:dashboard:shared"
        let sceneID = UUID()
        let gatewayID = UUID()
        let otherWindowTarget = DictationTarget(sceneID: UUID(), gatewayID: gatewayID, sessionKey: sessionKey)
        let otherGatewayTarget = DictationTarget(sceneID: sceneID, gatewayID: UUID(), sessionKey: sessionKey)
        let firstModel = DictationModel(engine: DictationTargetTestEngine())
        let secondWindowModel = DictationModel(engine: DictationTargetTestEngine())
        let otherGatewayModel = DictationModel(engine: DictationTargetTestEngine())
        let firstHost = NSHostingView(rootView: DictationTargetHost(
            app: app, model: firstModel, sceneID: sceneID, gatewayID: gatewayID,
            sessionKey: sessionKey, draft: DictationTargetDraft()))
        let secondWindowHost = NSHostingView(rootView: DictationTargetHost(
            app: app, model: secondWindowModel, sceneID: otherWindowTarget.sceneID, gatewayID: gatewayID,
            sessionKey: sessionKey, draft: DictationTargetDraft()))
        let otherGatewayHost = NSHostingView(rootView: DictationTargetHost(
            app: app, model: otherGatewayModel, sceneID: sceneID, gatewayID: otherGatewayTarget.gatewayID,
            sessionKey: sessionKey, draft: DictationTargetDraft()))
        let windows = [firstHost, secondWindowHost, otherGatewayHost].map { self.window(host: $0) }
        defer {
            for model in [firstModel, secondWindowModel, otherGatewayModel] { model.cancel() }
            for window in windows { window.close() }
        }

        firstHost.layoutSubtreeIfNeeded()
        secondWindowHost.layoutSubtreeIfNeeded()
        otherGatewayHost.layoutSubtreeIfNeeded()
        let target = DictationTarget(sceneID: sceneID, gatewayID: gatewayID, sessionKey: sessionKey)
        #expect(await eventually(timeout: .seconds(5)) { app.dictationAvailableTargets.count == 3 },
                "each available composer publishes its own window and Gateway identity")
        app.dictationToggleRequest = DictationToggleRequest(target: target, serial: 1)

        #expect(await eventually(timeout: .seconds(10)) { firstModel.phase == .listening })
        #expect(!secondWindowModel.isActive,
                "the same chat key in another window does not receive this scene's request")
        #expect(!otherGatewayModel.isActive,
                "the same chat key on another Gateway does not receive this request")
        #expect(app.dictationActiveTargets == [target], "active state is scoped to the initiating composer")
        #expect(app.dictationAvailableTargets == [target, otherWindowTarget, otherGatewayTarget],
                "available composers remain individually addressable in this palette")
    }

    @Test func inactivePaneDoesNotRespondOrPublishAvailability() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        let target = DictationTarget(sceneID: UUID(), gatewayID: UUID(), sessionKey: "agent:main:dashboard:shared")
        let model = DictationModel(engine: DictationTargetTestEngine())
        let host = NSHostingView(rootView: DictationTargetHost(
            app: app, model: model, sceneID: target.sceneID, gatewayID: target.gatewayID,
            sessionKey: target.sessionKey, draft: DictationTargetDraft(), paneIsActive: false))
        let window = self.window(host: host)
        defer { model.cancel(); window.close() }
        host.layoutSubtreeIfNeeded()
        app.dictationToggleRequest = DictationToggleRequest(target: target, serial: 1)

        for _ in 0..<20 { await Task.yield() }
        #expect(!model.isActive, "a matching request still waits for this split pane to own focus")
        #expect(!app.dictationAvailableTargets.contains(target), "an unfocused pane isn't offered in the palette")
    }

    private func window(host: NSHostingView<DictationTargetHost>) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 160, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        return window
    }
}
#endif
