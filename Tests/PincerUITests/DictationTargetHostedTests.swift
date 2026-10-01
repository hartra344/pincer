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
    let sessionKey: String
    @Bindable var draft: DictationTargetDraft

    var body: some View {
        DictationButton(model: self.model, app: self.app, sessionKey: self.sessionKey,
                        draft: Binding(get: { self.draft.text }, set: { self.draft.text = $0 }),
                        selection: nil, onCaret: { _ in }, isFieldFocused: false, onRequestFocus: {})
            .frame(width: 160, height: 60)
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
        let firstModel = DictationModel(engine: DictationTargetTestEngine())
        let secondModel = DictationModel(engine: DictationTargetTestEngine())
        let firstDraft = DictationTargetDraft()
        let secondDraft = DictationTargetDraft()
        let firstHost = NSHostingView(rootView: DictationTargetHost(
            app: app, model: firstModel, sessionKey: sessionKey, draft: firstDraft))
        let secondHost = NSHostingView(rootView: DictationTargetHost(
            app: app, model: secondModel, sessionKey: sessionKey, draft: secondDraft))
        let firstWindow = self.window(host: firstHost)
        let secondWindow = self.window(host: secondHost)
        defer {
            firstModel.cancel()
            secondModel.cancel()
            firstWindow.close()
            secondWindow.close()
        }

        firstHost.layoutSubtreeIfNeeded()
        secondHost.layoutSubtreeIfNeeded()
        app.dictationToggleRequest = DictationToggleRequest(sessionKey: sessionKey, serial: 1)

        #expect(await eventually(timeout: .seconds(10)) { firstModel.phase == .listening })
        #expect(!secondModel.isActive,
                "a request captured in one window must not start the same-key composer in another window")
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
