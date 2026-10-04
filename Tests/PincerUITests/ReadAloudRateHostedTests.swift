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

/// The actual section evaluates its stored-rate accessibility percentage during rendering.
/// The oversized case intentionally traps the old unchecked Float-to-Int conversion.
@MainActor
@Suite("Read Aloud stored rate rendering", .serialized)
struct ReadAloudRateHostedTests {
    private func render(_ rate: Double) async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set(rate, forKey: ReadAloudSettings.rateKey)
        #expect(rate.isNaN ? scratch.defaults.double(forKey: ReadAloudSettings.rateKey).isNaN
                           : scratch.defaults.double(forKey: ReadAloudSettings.rateKey) == rate)
        let app = AppModel(defaults: scratch.defaults)
        let state = DeviceSpeechCatalog { locale in
            DeviceSpeechCatalogSnapshot(localeIdentifier: locale, voices: [], dictationSupport: nil)
        }
        let catalog = AppleDeviceSpeechCatalog(state: state, observeSystemChanges: false)
        let form = Form { ReadAloudSettingsSection(catalog: catalog) }
            .environment(app)
            .defaultAppStorage(scratch.defaults)
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
        #expect(host.view.bounds.width == 390 && host.view.bounds.height > 0)
        #elseif os(macOS)
        let host = NSHostingView(rootView: form)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height.isFinite && host.fittingSize.height > 0)
        #endif
    }

    @Test(.timeLimit(.minutes(1))) func oversizedFiniteStoredRateRendersActualSettingsWithoutTrap() async {
        await self.render(Double.greatestFiniteMagnitude)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [Double.nan, .infinity, -.infinity, -Double.greatestFiniteMagnitude])
    func invalidStoredRatesRenderActualSettings(_ rate: Double) async {
        await self.render(rate)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0.3, 0.5, 0.7])
    func ordinaryStoredRateControlsRenderActualSettings(_ rate: Double) async {
        await self.render(rate)
    }
}
