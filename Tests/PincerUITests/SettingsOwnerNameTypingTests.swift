#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class OwnerNameDefaultsRecorder {
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private(set) var changedValues: [String?] = []
    private var lastValue: String?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.lastValue = defaults.string(forKey: "pincer.ownerName")
        self.observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = self.defaults.string(forKey: "pincer.ownerName")
                if value != self.lastValue {
                    self.changedValues.append(value)
                    self.lastValue = value
                }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
    }
}

/// #661: typing into the actual iOS Display name field should not fan one defaults write out for
/// every character to each open transcript's global settings observers.
@MainActor
struct SettingsOwnerNameTypingProbe {
    private static func fields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap { self.fields(in: $0) }
    }

    /// SwiftPM's hosted iOS test process dispatches these registered editing targets directly.
    private static func editingChanged(_ field: UITextField) -> Int {
        var invoked = 0
        for target in field.allTargets {
            guard let object = target.base as? NSObject else { continue }
            for action in field.actions(forTarget: object, forControlEvent: .editingChanged) ?? [] {
                _ = object.perform(NSSelectorFromString(action), with: field)
                invoked += 1
            }
        }
        return invoked
    }

    func displayNameTypingCoalescesGlobalDefaultsWritesAndPersistsExactText() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        let form = SettingsForm(sections: [.you]).environment(app).defaultAppStorage(scratch.defaults)
        let host = UIHostingController(rootView: form)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 420))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        let loaded = await eventually {
            host.view.layoutIfNeeded()
            return !Self.fields(in: host.view).isEmpty
        }
        #expect(loaded, "host the real You settings field")
        let field = try #require(Self.fields(in: host.view).first)
        let recorder = OwnerNameDefaultsRecorder(defaults: scratch.defaults)
        defer { recorder.stop() }

        var text = ""
        for character in "Maya Chen" {
            text.append(character)
            field.text = text
            #expect(Self.editingChanged(field) > 0, "the hosted display-name field accepts editing changes")
            await Task.yield()
        }

        #expect(await eventually { !recorder.changedValues.isEmpty },
                "the actual owner-name write should reach UserDefaults.didChangeNotification")
        #expect(recorder.changedValues.count <= 1,
                "typing a name should coalesce defaults notifications instead of writing once per character (\(recorder.changedValues))")
        #expect(await eventually(timeout: .seconds(2)) { scratch.defaults.string(forKey: "pincer.ownerName") == text },
                "the debounced owner name must persist exactly after typing stops")
    }
}

extension TranscriptUIKitHostedTests {
    @Test func settingsOwnerNameTypingCoalescesDefaultsWrites() async throws {
        try await SettingsOwnerNameTypingProbe().displayNameTypingCoalescesGlobalDefaultsWritesAndPersistsExactText()
    }
}
#endif
