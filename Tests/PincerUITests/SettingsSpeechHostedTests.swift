import Foundation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Hold a real discovery worker open while the native form lays out and accepts a scroll.
/// Never wait on the main thread, even if a regression sends discovery there.
private final class SettingsDiscoveryGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var started = false
    private var calls = 0
    private var ranOnMain = false

    var hasStarted: Bool { self.condition.withLock { self.started } }
    var callCount: Int { self.condition.withLock { self.calls } }
    var discoveredOnMain: Bool { self.condition.withLock { self.ranOnMain } }

    func discover(locale: String) -> DeviceSpeechCatalogSnapshot {
        self.condition.lock()
        self.started = true
        self.calls += 1
        self.ranOnMain = Thread.isMainThread
        if !Thread.isMainThread {
            let deadline = Date().addingTimeInterval(5)
            while !self.released && self.condition.wait(until: deadline) {}
        }
        self.condition.unlock()
        return DeviceSpeechCatalogSnapshot(localeIdentifier: locale,
            voices: [DeviceSpeechVoice(id: "settings.saved-voice", name: "Saved Voice", language: "en-US", quality: 2)],
            dictationSupport: DeviceDictationSupport(language: "English", supported: true))
    }

    func release() {
        self.condition.lock()
        self.released = true
        self.condition.broadcast()
        self.condition.unlock()
    }
}

@MainActor
@Suite("Settings speech discovery responsiveness", .serialized)
struct SettingsSpeechHostedTests {
    @Test func nativeFormScrollsWhileSpeechDiscoveryIsPending() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set("settings.saved-voice", forKey: ReadAloudSettings.deviceVoiceKey)
        let app = AppModel(defaults: scratch.defaults)
        let gate = SettingsDiscoveryGate()
        defer { gate.release() }
        let state = DeviceSpeechCatalog { gate.discover(locale: $0) }
        let catalog = AppleDeviceSpeechCatalog(state: state, observeSystemChanges: false)
        catalog.refresh()
        #expect(await eventually { gate.hasStarted })
        #expect(state.isRefreshing && state.snapshot == nil)
        #expect(!gate.discoveredOnMain)

        let form = SettingsForm(sections: [.conversation, .readAloud, .dictation, .location, .sidebar],
                                speechCatalog: catalog)
            .environment(app)
            .defaultAppStorage(scratch.defaults)
        let start = ContinuousClock.now
        #if os(iOS)
        let host = UIHostingController(rootView: form)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.loadViewIfNeeded()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        for _ in 0..<4 { await Task.yield() }
        host.view.layoutIfNeeded()
        let scroll = self.scrollView(in: host.view)
        #expect(scroll != nil, "exercise the actual grouped Settings form's native scroller")
        if let scroll {
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
            #expect(maximum > 0, "the conversation settings extend past the viewport")
            scroll.setContentOffset(CGPoint(x: 0, y: maximum / 2), animated: false)
            scroll.layoutIfNeeded()
            #expect(scroll.contentOffset.y > 0)
            scroll.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
            scroll.layoutIfNeeded()
        }
        #elseif os(macOS)
        let host = NSHostingView(rootView: form)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 450)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
        #endif
        let elapsed = start.duration(to: .now)
        print("Settings form while speech discovery is pending: \(elapsed)")
        #expect(elapsed < PerfBudget.limit(.milliseconds(200)),
                "form layout and scrolling must not wait for speech discovery")
        #expect(state.isRefreshing && state.snapshot == nil,
                "the native interaction completed before the held worker")
        #expect(gate.callCount == 1, "both sections share one in-flight discovery")
        #expect(scratch.defaults.string(forKey: ReadAloudSettings.deviceVoiceKey) == "settings.saved-voice",
                "loading the picker must not overwrite its saved voice")
        gate.release()
        #expect(await eventually { state.snapshot?.voices.first?.id == "settings.saved-voice" })
    }

    #if os(iOS)
    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = self.scrollView(in: child) { return scroll }
        }
        return nil
    }
    #endif
}
