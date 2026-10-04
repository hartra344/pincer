#if os(iOS) && DEBUG
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)))
    func chatHeaderAvatarSizeUsesActualPickerAndPersistentGeometry() async throws {
        let diagnostic = AvatarPhaseDiagnostics()
        func phase(_ value: AvatarPhaseDiagnostics.Phase, ready: Bool = false, width: Double = 0, height: Double = 0) {
            diagnostic.enter(value, ready: ready, width: width, height: height)
            print(diagnostic.report())
        }
        defer { print(diagnostic.report()) }
        try await withTaskCancellationHandler {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let gateway = app.add(.demo(), secret: nil)
        gateway.cacheRoot = nil
        gateway.notifier = nil
        scratch.defaults.set(false, forKey: AvatarSettings.animatedKey)
        phase(.connection)
        try #require(await eventually(timeout: .seconds(30)) {
            gateway.state.isConnected && gateway.sessions["agent:main:dashboard:trip"] != nil
        })
        let key = "agent:main:dashboard:trip"
        gateway.selectedKey = key
        let chat = gateway.chat(for: key)
        phase(.history, ready: gateway.state.isConnected)
        await chat.load()
        let host = CenteredChatHeaderNativeFixtures.Host(app: app, gateway: gateway, width: 390)
        defer { host.close() }
        // Host the actual Appearance section, with animation disabled. Its real segmented
        // control must still exist and write the same scratch AppStorage as the live header.
        let picker = UIHostingController(rootView: Form { AvatarSettingsSection() }
            .environment(app).defaultAppStorage(scratch.defaults))
        let pickerWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        pickerWindow.rootViewController = picker
        pickerWindow.isHidden = false
        defer { pickerWindow.isHidden = true }
        phase(.picker)
        try #require(await eventually(timeout: .seconds(15)) {
            pickerWindow.layoutIfNeeded()
            return CenteredChatHeaderNativeFixtures.views(pickerWindow).contains { $0 is UISegmentedControl }
        }, "The actual animation-off Appearance section must expose its native size picker")
        let control = try #require(CenteredChatHeaderNativeFixtures.views(pickerWindow)
            .compactMap { $0 as? UISegmentedControl }.first)
        #expect(control.numberOfSegments == 2)
        #expect(control.titleForSegment(at: 0) == "Small" && control.titleForSegment(at: 1) == "Large")
        phase(.defaultGeometry, ready: control.window != nil)
        try #require(await eventually(timeout: .seconds(15)) {
            host.geometry.frames[.avatar]?.width == 48 && host.geometry.frames[.reservation]?.height == 44
        }, "An unset preference renders the actual default Small header")
        #expect(control.selectedSegmentIndex == 0)
        // AppStorage's default need not be written when reselecting the already selected
        // segment. Drive three actual changes instead, requiring persistence each time.
        for (index, raw, size, reserve) in [(1, "large", CGFloat(64), CGFloat(60)), (0, "small", 48, 44), (1, "large", 64, 60)] {
            phase(index == 0 ? .small : (reserve == 60 && scratch.defaults.string(forKey: ChatHeaderAvatarSize.defaultsKey) == "small" ? .largeAgain : .largeFirst))
            control.selectedSegmentIndex = index
            // The package XCTest process has no UIApplication dispatcher. Invoke the
            // actual SwiftUI-registered native selector, as existing field fixtures do.
            var invoked = 0
            for target in control.allTargets {
                guard let object = target.base as? NSObject else { continue }
                for action in control.actions(forTarget: object, forControlEvent: .valueChanged) ?? [] {
                    _ = object.perform(NSSelectorFromString(action), with: control)
                    invoked += 1
                }
            }
            try #require(invoked > 0, "The real segmented control must have a registered selection action")
            try #require(await eventually(timeout: .seconds(15)) {
                host.window.layoutIfNeeded()
                return scratch.defaults.string(forKey: ChatHeaderAvatarSize.defaultsKey) == raw
                    && abs((host.geometry.frames[.avatar]?.width ?? 0) - size) < 1
                    && abs((host.geometry.frames[.reservation]?.height ?? 0) - reserve) < 1
            }, "Actual native picker action must persist and update the existing header: selection=\(index), stored=\(scratch.defaults.string(forKey: ChatHeaderAvatarSize.defaultsKey) ?? "nil"), frames=\(host.geometry.frames)")
            let avatar = try #require(host.geometry.frames[.avatar])
            let title = try #require(host.geometry.frames[.title])
            let reservation = try #require(host.geometry.frames[.reservation])
            #expect(abs(avatar.height - size) < 1 && abs(avatar.midX - 195) < 1)
            #expect(title.minY >= avatar.maxY && title.maxY <= reservation.maxY + 1)
        }
        phase(.accessibilityGeometry, width: Double(host.geometry.frames[.avatar]?.width ?? 0), height: Double(host.geometry.frames[.reservation]?.height ?? 0))
        var content = host.controller.rootView
        content.dynamicTypeSize = .accessibility5
        host.controller.rootView = content
        try #require(await eventually(timeout: .seconds(15)) {
            host.window.layoutIfNeeded()
            guard let avatar = host.geometry.frames[.avatar], let title = host.geometry.frames[.title],
                  let reservation = host.geometry.frames[.reservation] else { return false }
            return abs(avatar.width - 64) < 1 && title.height > 40 && title.maxY <= reservation.maxY + 1
        }, "Large avatar and actual accessibility title must fit the measured reservation")
        phase(.send)
        _ = await chat.sendMessage("approve", includeLocation: false)
        phase(.approval)
        try #require(await eventually(timeout: .seconds(20)) { gateway.approvals.contains { $0.sessionKey == key } })
        app.findRequest = FindRequest(target: Notifier.Target(gatewayId: gateway.id, sessionKey: key), query: "trip", match: nil)
        let geometryTolerance = 1 / host.window.screen.scale
        phase(.overlays, ready: !gateway.approvals.isEmpty)
        let overlaysReady = await eventually(timeout: .seconds(15)) {
            host.window.layoutIfNeeded()
            host.controller.view.layoutIfNeeded()
            guard let title = host.geometry.frames[.title], let find = host.topChrome.frames[.find],
                  let approvals = host.topChrome.frames[.approvals] else { return false }
            return find.height > 0 && approvals.height > 0 && find.minY + geometryTolerance >= title.maxY
                && approvals.minY + geometryTolerance >= title.maxY
                && find.minY + geometryTolerance >= approvals.maxY
        }
        if !overlaysReady { print(diagnostic.report()) }
        try #require(overlaysReady, "Actual Find and Demo approval controls must remain below the expanded header")
        phase(.reopened)
        let reopened = CenteredChatHeaderNativeFixtures.Host(app: app, gateway: gateway, width: 390)
        defer { reopened.close() }
        try #require(await eventually(timeout: .seconds(15)) { reopened.geometry.frames[.avatar]?.width == 64 },
                     "A new actual header must read the persisted Large selection")
        phase(.complete, ready: true)
        } onCancel: {
            // Lock-backed snapshot: do not queue this report behind a stalled Main actor.
            print(diagnostic.report())
        }
    }
}
#endif
