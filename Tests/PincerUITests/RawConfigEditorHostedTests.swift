#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Actual raw config editor ownership", .serialized)
struct RawConfigEditorHostedTests {
    @MainActor
    private final class Server {
        var raw = "{\"gateway\":{\"port\":18789}}"
        var submitted: String?
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        func release() { released = true; let old = waiter; waiter = nil; old?.resume() }
        func request(_ method: String, _ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue {
            switch method {
            case "config.get":
                return ["raw": .string(raw), "resolved": try JSONValue.decode(Data(raw.utf8)),
                        "hash": .string(submitted == nil ? "before" : "after"), "valid": true]
            case "config.apply":
                #expect(timeout == 60 && params["baseHash"] == "before")
                let value = try #require(params["raw"]?.text)
                submitted = value
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
                    }
                } onCancel: { Task { @MainActor in self.release() } }
                try Task.checkCancellation()
                raw = value
                return ["ok": true]
            case "plugins.list": return ["plugins": []]
            default: Issue.record("Unexpected raw editor RPC: \(method)"); return [:]
            }
        }
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(self.views) }
    private func edit(_ field: UITextView, _ value: String) {
        field.text = value
        field.delegate?.textViewDidChange?(field)
    }
    private func toolbarItems(_ window: UIWindow) -> [UIBarButtonItem] {
        self.views(window).compactMap { $0 as? UINavigationBar }.flatMap { bar in
            (bar.topItem?.trailingItemGroups.flatMap(\.barButtonItems) ?? [])
                + (bar.topItem?.rightBarButtonItems ?? [])
        }
    }
    private func saveEnabled(_ window: UIWindow) -> Bool {
        self.toolbarItems(window).contains { ($0.title == "Save" || $0.accessibilityLabel == "Save") && $0.isEnabled }
    }
    private func activate(_ label: String, window: UIWindow) -> Bool {
        if label == "Save", !self.saveEnabled(window) { return false }
        for item in self.toolbarItems(window) where item.isEnabled && (item.title == label || item.accessibilityLabel == label) {
            if let target = item.target as? NSObject, let action = item.action, target.responds(to: action) {
                target.perform(action, with: item)
                return true
            }
            if item.accessibilityActivate() { return true }
        }
        for object in CenteredChatHeaderNativeFixtures.objects(window) where object.accessibilityLabel == label && !object.accessibilityTraits.contains(.notEnabled) {
            if let control = object as? UIControl {
                guard control.isEnabled else { continue }
                var invoked = 0
                for target in control.allTargets {
                    guard let receiver = target as? NSObject else { continue }
                    for action in control.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                        let selector = NSSelectorFromString(action)
                        guard receiver.responds(to: selector) else { continue }
                        receiver.perform(selector, with: control)
                        invoked += 1
                    }
                }
                if invoked > 0 { return true }
            }
            if object.accessibilityActivate() { return true }
        }
        print("Raw config actual toolbar action missing: \(label); accessibility labels=\(CenteredChatHeaderNativeFixtures.labels(window))")
        print("Raw config public toolbar items: \(self.toolbarItems(window).map { "title=\($0.title ?? "nil") label=\($0.accessibilityLabel ?? "nil") target=\(String(describing: $0.target)) action=\(String(describing: $0.action))" })")
        return false
    }
    enum Later: String, CaseIterable, Sendable { case unchanged, changed, revert, aba }
    @Test(.timeLimit(.minutes(2)), arguments: Later.allCases)
    func actualSaveRetainsOnlyPostAdmissionEditorIntent(_ later: Later) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let server = Server()
        let model = GatewaySettingsModel(request: { try await server.request($0, $1, $2) },
                                        scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        let baseline = server.raw
        let admitted = "{\"gateway\":{\"port\":18790}}"
        let newer = "{\"gateway\":{\"port\":18791}}"
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop(); server.release() }
        let host = UIHostingController(rootView: NavigationStack { RawConfigPage(settings: model) }.environment(gateway))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try #require(await eventually { window.layoutIfNeeded(); return self.views(window).contains { ($0 as? UITextView)?.text == baseline } })
        let field = try #require(self.views(window).compactMap { $0 as? UITextView }.first)
        edit(field, admitted)
        let saveReady = await eventually(timeout: .seconds(15)) {
            window.layoutIfNeeded()
            return self.saveEnabled(window)
        }
        if !saveReady {
            print("Raw config Save readiness: public items=\(self.toolbarItems(window).map { String(describing: $0.title) + " target=" + String(describing: $0.target) + " action=" + String(describing: $0.action) }); AX=\(CenteredChatHeaderNativeFixtures.labels(window))")
        }
        try #require(saveReady, "Actual public native toolbar enables Save after current validation")
        try #require(activate("Save", window: window), "Invoke the actual native toolbar Save action")
        try #require(await eventually { server.submitted == admitted && model.isSaving })
        switch later {
        case .unchanged: break
        case .changed: edit(field, newer)
        case .revert:
            try #require(activate("Revert", window: window), "Invoke actual toolbar Revert after Save admission")
            try #require(await eventually { field.text == baseline })
        case .aba: edit(field, newer); edit(field, baseline)
        }
        server.release()
        try #require(await eventually { !model.isSaving && model.snapshot?.raw == admitted })
        for _ in 0..<4 { await Task.yield() }; window.layoutIfNeeded()
        #expect(field.text == (later == .unchanged ? admitted : later == .changed ? newer : baseline),
                "Actual acknowledgement must not replace later editor typing or explicit Revert/ABA")
        #expect(server.submitted == admitted, "Only the captured raw file reaches config.apply")
    }
    @Test(.timeLimit(.minutes(2))) func actualEditedBodyDoesNotParseJSON5OnMain() async throws {
        let large = await Task.detached { "{\"opening\":\"meaningful\",\"body\":\"" + String(repeating: "x", count: 2 * 1024 * 1024) + "\"}" }.value
        #expect(RawConfigPage.parseError("{ /* JSON5 */ value: 1, }") == nil)
        #expect(RawConfigPage.parseError("{broken") != nil)
        let scratch = ScratchDefaults(); defer { scratch.remove() }
        let server = Server()
        let model = GatewaySettingsModel(request: { try await server.request($0, $1, $2) }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; defer { gateway.stop() }
        let probe = RawConfigParserProbe()
        let host = UIHostingController(rootView: NavigationStack { RawConfigPage(settings: model) }
            .environment(gateway).environment(\.rawConfigParserProbe, probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try #require(await eventually { window.layoutIfNeeded(); return self.views(window).contains { $0 is UITextView } })
        let field = try #require(self.views(window).compactMap { $0 as? UITextView }.first)
        edit(field, large)
        try #require(await eventually { probe.counts.main + probe.counts.background > 0 }, "Actual editor body must reach real validation")
        #expect(probe.counts.main == 0, "Actual JSON5 validation must run off Main")
        #expect(field.text == large)
        try #require(await eventually(timeout: .seconds(15)) { window.layoutIfNeeded(); return self.saveEnabled(window) },
                     "The completed current valid source enables the actual Save item")
        let before = probe.counts.background
        edit(field, "{invalid")
        edit(field, "{ valid: 1 }")
        edit(field, "{latest-invalid")
        try #require(await eventually(timeout: .seconds(15)) {
            window.layoutIfNeeded()
            return probe.counts.background > before && !self.saveEnabled(window)
        }, "Latest invalid text must disable Save despite an intervening valid edit")
        #expect(field.text == "{latest-invalid" && server.submitted == nil)
        #expect(!activate("Save", window: window), "The native fixture must refuse disabled Save actions")
        #expect(probe.counts.main == 0)
    }
}
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)), arguments: RawConfigEditorHostedTests.Later.allCases)
    func actualRawConfigSavePreservesLaterEditorIntent(_ later: RawConfigEditorHostedTests.Later) async throws {
        try await RawConfigEditorHostedTests().actualSaveRetainsOnlyPostAdmissionEditorIntent(later)
    }
    @Test(.timeLimit(.minutes(2))) func actualRawConfigJSON5ValidationStaysOffMain() async throws {
        try await RawConfigEditorHostedTests().actualEditedBodyDoesNotParseJSON5OnMain()
    }
}
#endif
