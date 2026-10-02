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

private actor HeldOwnerNameWait {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if self.released { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func releaseAll() {
        self.released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
    private static func editingChanged(_ field: UITextField, event: UIControl.Event = .editingChanged) -> Int {
        var invoked = 0
        for target in field.allTargets {
            guard let object = target.base as? NSObject else { continue }
            for action in field.actions(forTarget: object, forControlEvent: event) ?? [] {
                _ = object.perform(NSSelectorFromString(action), with: field)
                invoked += 1
            }
        }
        return invoked
    }

    func displayNameTypingCoalescesAndDisappearFlushesExactText() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let wait = HeldOwnerNameWait()
        let app = AppModel(defaults: scratch.defaults, ownerNameIdleWait: { _ in await wait.wait() })
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

        #expect(scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == nil,
                "typing remains local while the idle wait is held")
        text = "Maya Chen "
        field.text = text
        #expect(Self.editingChanged(field) > 0)
        await Task.yield()
        text.append("2")
        field.text = text
        #expect(Self.editingChanged(field) > 0)
        await Task.yield()
        host.rootView = SettingsForm(sections: []).environment(app).defaultAppStorage(scratch.defaults)
        #expect(await eventually { scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == text },
                "leaving the real section flushes its latest draft while idle commits are still held")
        host.rootView = form
        #expect(await eventually {
            host.view.layoutIfNeeded()
            return Self.fields(in: host.view).first?.text == text
        }, "reopening Settings reads the persisted display name from the same app model")
        // The serial writer can publish the value before its main-queue defaults notification runs.
        #expect(await eventually { recorder.changedValues == ["Maya Chen 2"] },
                "typing remains local, then section departure publishes one completed name")
        await wait.releaseAll()
    }

    func displayNameIdleAutosavePersistsOnlyLatestValue() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let wait = HeldOwnerNameWait()
        let app = AppModel(defaults: scratch.defaults, ownerNameIdleWait: { _ in await wait.wait() })
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
        #expect(loaded, "host the real You settings field for idle-save coverage")
        let field = try #require(Self.fields(in: host.view).first)
        let recorder = OwnerNameDefaultsRecorder(defaults: scratch.defaults)
        defer { recorder.stop() }

        var text = ""
        for character in "Maya Chen" {
            text.append(character)
            field.text = text
            #expect(Self.editingChanged(field) > 0)
            await Task.yield()
        }
        #expect(scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == nil,
                "the held idle wait prevents premature persistence")
        await wait.releaseAll()
        #expect(await eventually { scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == text },
                "the actual field's idle autosave persists the final value")
        // Wait for notification delivery separately from persistence: the two queues are independent.
        #expect(await eventually { recorder.changedValues == [text] },
                "the idle save publishes only the final name, without intermediate keystroke notifications")
    }
}

extension TranscriptUIKitHostedTests {
    @Test func settingsOwnerNameTypingCoalescesDefaultsWrites() async throws {
        try await SettingsOwnerNameTypingProbe().displayNameTypingCoalescesAndDisappearFlushesExactText()
    }

    @Test func settingsOwnerNameIdleAutosavesLatestValue() async throws {
        try await SettingsOwnerNameTypingProbe().displayNameIdleAutosavePersistsOnlyLatestValue()
    }
}
#endif
