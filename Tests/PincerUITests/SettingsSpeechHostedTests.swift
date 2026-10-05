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
    #if DEBUG
    private let workerGate = ExplicitWorkerTestGate()
    private var expired = false
    private var expiry: DispatchWorkItem?
    var holdExpired: Bool { self.condition.withLock { self.expired } }
    private func recordHold() {
        self.condition.withLock { self.started = true }
    }
    private func recordExpiry() {
        self.condition.withLock { self.expired = true }
        self.workerGate.open()
    }
    func holdAfterDiscovery() async {
        self.recordHold()
        let action: @Sendable () -> Void = { [self] in self.recordExpiry() }
        let timer = DispatchWorkItem(block: action)
        self.condition.withLock { self.expiry = timer }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
        await self.workerGate.hold()
        let completedTimer = self.condition.withLock { () -> DispatchWorkItem? in
            guard self.expiry === timer else { return nil }
            let value = self.expiry
            self.expiry = nil
            return value
        }
        completedTimer?.cancel()
    }
    func waitUntilEntered() async -> Bool { await self.workerGate.waitUntilEntered(timeout: 3) }
    #endif

    var hasStarted: Bool { self.condition.withLock { self.started } }
    var callCount: Int { self.condition.withLock { self.calls } }
    var discoveredOnMain: Bool { self.condition.withLock { self.ranOnMain } }

    func discover(locale: String) -> DeviceSpeechCatalogSnapshot {
        self.condition.lock()
        #if !DEBUG
        self.started = true
        #endif
        self.calls += 1
        self.ranOnMain = Thread.isMainThread
        #if !DEBUG
        if !Thread.isMainThread {
            let deadline = Date().addingTimeInterval(5)
            while !self.released && self.condition.wait(until: deadline) {}
        }
        #endif
        self.condition.unlock()
        return DeviceSpeechCatalogSnapshot(localeIdentifier: locale,
            voices: [DeviceSpeechVoice(id: "settings.saved-voice", name: "Saved Voice", language: "en-US", quality: 2)],
            dictationSupport: DeviceDictationSupport(language: "English", supported: true))
    }

    func release() {
        #if DEBUG
        let timer = self.condition.withLock { () -> DispatchWorkItem? in
            let value = self.expiry
            self.expiry = nil
            return value
        }
        timer?.cancel()
        self.workerGate.open()
        #else
        self.condition.lock()
        self.released = true
        self.condition.broadcast()
        self.condition.unlock()
        #endif
    }
}

@MainActor
@Suite("Settings speech discovery responsiveness", .serialized)
struct SettingsSpeechHostedTests {
    @Test func nativeFormScrollsWhileSpeechDiscoveryIsPending() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set("settings.saved-voice", forKey: ReadAloudSettings.deviceVoiceKey)
        let app = AppModel(defaults: scratch.defaults)
        let gate = SettingsDiscoveryGate()
        defer { gate.release() }
        let state = DeviceSpeechCatalog { gate.discover(locale: $0) }
        #if DEBUG
        state.discoveryCompletionHoldForTesting = { _ in await gate.holdAfterDiscovery() }
        #endif
        let catalog = AppleDeviceSpeechCatalog(state: state, observeSystemChanges: false)
        catalog.refresh()
        #if DEBUG
        let actualWorker = state.actualDiscoveryTaskForTesting
        #endif
        var closeWindow: (() -> Void)?
        defer { closeWindow?() }
        do {
            #if DEBUG
            try #require(actualWorker != nil)
            let entered = await gate.waitUntilEntered()
            try Task.checkCancellation()
            try #require(entered)
            #endif
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
            closeWindow = { window.isHidden = true; window.rootViewController = nil }
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
            closeWindow = { window.close() }
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
            #if DEBUG
            try Task.checkCancellation()
            #expect(!gate.holdExpired, "the original five-second safety expiry cannot qualify held interaction")
            #endif
            gate.release()
            #if DEBUG
            await actualWorker?.value
            #endif
            #expect(await eventually { state.snapshot?.voices.first?.id == "settings.saved-voice" })
            #if DEBUG
            #expect(await eventually { !state.isRefreshing && state.actualDiscoveryTaskForTesting == nil })
            #endif
        } catch {
            gate.release()
            #if DEBUG
            await actualWorker?.value
            #expect(await eventually { !state.isRefreshing && state.actualDiscoveryTaskForTesting == nil })
            #endif
            throw error
        }
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
