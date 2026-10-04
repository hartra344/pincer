#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Voice settings draft ownership", .serialized)
struct VoiceSettingsDraftOwnershipHostedTests {
    @MainActor private final class Server {
        var config: JSONValue = ["tts": ["providers": ["elevenlabs": ["voiceSettings": TTSVoiceSettings.elevenLabsDefault.json]]]]
        var submitted: JSONValue?
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        func release() { released = true; let old = waiter; waiter = nil; old?.resume() }
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            switch method {
            case "config.get": return ["config": config, "hash": "voice-before"]
            case "config.patch":
                #expect(params["baseHash"] == "voice-before")
                let raw = try #require(params["raw"]?.text)
                let patch = try JSONValue.decode(Data(raw.utf8))
                submitted = patch
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
                    }
                } onCancel: { Task { @MainActor in self.release() } }
                try Task.checkCancellation()
                config = config.applyingMergePatch(patch)
                return ["ok": true]
            case "tts.status": return ["provider": "elevenlabs", "enabled": false, "providerStates": []]
            case "tts.providers": return ["providers": []]
            case "tts.personas": return ["personas": []]
            case "secrets.store.list": return ["entries": []]
            default: Issue.record("Unexpected voice-settings RPC: \(method)"); return [:]
            }
        }
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(self.views) }
    @discardableResult private func dispatch(_ control: UIControl, _ event: UIControl.Event) -> Int {
        var invoked = 0
        for target in control.allTargets {
            guard let receiver = target as? NSObject else { continue }
            for action in control.actions(forTarget: target, forControlEvent: event) ?? [] {
                let selector = NSSelectorFromString(action)
                if receiver.responds(to: selector) { receiver.perform(selector, with: control); invoked += 1 }
            }
        }
        if invoked == 0 { control.sendActions(for: event) }
        return invoked
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func actualAcknowledgementPreservesAnInProgressSecondSlider(_ laterEdit: Bool) async throws {
        let server = Server()
        let model = GatewayVoiceModel(request: { try await server.request($0, $1) })
        await model.refresh()
        let setup = VoiceSetupController()
        let host = UIHostingController(rootView: NavigationStack { Form {
            VoiceSetupSettingsSection(model: model, setup: setup, provider: "elevenlabs", editable: true, initialExpanded: true)
        } })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { server.release(); window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        for _ in 0..<4 { await Task.yield() }
        print("Voice native initial inventory: attached=\(host.view.window != nil) bounds=\(host.view.bounds) labels=\(CenteredChatHeaderNativeFixtures.labels(window)) controls=\(self.views(window).compactMap { $0 as? UIControl }.map { String(describing: type(of: $0)) + ":" + ($0.accessibilityLabel ?? "nil") })")
        let slidersReady = await eventually { window.layoutIfNeeded(); return self.views(window).compactMap { $0 as? UISlider }.count == 4 }
        if !slidersReady { print("Actual initially-open voice section views=\(self.views(window).map { String(describing: type(of: $0)) }); labels=\(CenteredChatHeaderNativeFixtures.labels(window))") }
        try #require(slidersReady, "The actual initially-open section must expose four native sliders")
        let sliders = self.views(window).compactMap { $0 as? UISlider }
        print("Actual voice slider inventory: \(sliders.map { "range=\($0.minimumValue)...\($0.maximumValue) value=\($0.value) frame=\($0.convert($0.bounds, to: window))" })")
        #expect(sliders.allSatisfy { $0.minimumValue == 0 && $0.maximumValue == 1 },
                "SwiftUI's actual native controls use normalized ranges")
        let initialSpeed = Float((TTSVoiceSettings.elevenLabsDefault.speed - 0.5) / 1.5)
        let speeds = sliders.filter { $0.minimumValue == 0 && $0.maximumValue == 1 && abs($0.value - initialSpeed) < 0.001 }
        let stabilities = sliders.filter {
            $0.minimumValue == 0 && $0.maximumValue == 1
                && abs($0.value - Float(TTSVoiceSettings.elevenLabsDefault.stability)) < 0.001
        }
        try #require(speeds.count == 1 && stabilities.count == 1,
                     "Native ranges and distinct initial values must uniquely identify the real Speed and Stability controls")
        let speed = try #require(speeds.first)
        let stability = try #require(stabilities.first)
        #expect(abs(speed.value - initialSpeed) < 0.001)
        #expect(stability.value == Float(TTSVoiceSettings.elevenLabsDefault.stability))
        #expect(speed.convert(speed.bounds, to: window).minY < stability.convert(stability.bounds, to: window).minY,
                "Actual native control geometry follows the production Speed then Stability order")
        try #require(speed.isEnabled && stability.isEnabled)
        dispatch(speed, .touchDown)
        let requestedSpeed: Float = Float((1.5 - 0.5) / 1.5)
        speed.value = requestedSpeed
        dispatch(speed, .valueChanged)
        dispatch(speed, .touchUpInside)
        try #require(await eventually { server.submitted != nil && setup.busy })
        let captured = try #require(server.submitted?["tts"]?["providers"]?["elevenlabs"]?["voiceSettings"])
        let capturedSpeed = try #require(captured["speed"]?.double)
        #expect(abs(capturedSpeed - 1.5) <= Double(Float.ulpOfOne) * 1.5,
                "The real normalized native slider maps to the requested production speed")
        if laterEdit {
            dispatch(stability, .touchDown)
            stability.value = 0.8
            dispatch(stability, .valueChanged)
        }
        server.release()
        try #require(await eventually { !setup.busy && model.setups["elevenlabs"]?.voiceSettings?.speed == capturedSpeed })
        for _ in 0..<4 { await Task.yield() }; window.layoutIfNeeded()
        #expect(abs(speed.value - requestedSpeed) < 0.001, "Actual accepted first normalized slider remains saved")
        #expect(abs(stability.value - Float(laterEdit ? 0.8 : TTSVoiceSettings.elevenLabsDefault.stability)) < 0.001,
                "Acknowledgement of the first slider must preserve a later in-progress slider draft")
        #expect(captured["stability"]?.double == TTSVoiceSettings.elevenLabsDefault.stability,
                "Only the admitted settings reach the actual config.patch")
        #expect(setup.error == nil)
    }
}

@MainActor
private final class VoiceRunGate {
    var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        self.entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if self.released || Task.isCancelled { waiter.resume() } else { self.waiter = waiter }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { self.released = true; let old = self.waiter; self.waiter = nil; old?.resume() }
}

extension VoiceSettingsDraftOwnershipHostedTests {
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func actualRunKeepsLatestOutcomeAndAllPendingWork(_ newerFailsFirst: Bool) async throws {
        let setup = VoiceSetupController()
        let older = VoiceRunGate(), newer = VoiceRunGate()
        let taskA = Task { await setup.run("older") { await older.wait(); return .applied } }
        defer { taskA.cancel(); older.release() }
        try #require(await eventually { older.entered })
        let taskB = Task { await setup.run("newer") {
            await newer.wait()
            if newerFailsFirst { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "newer fixture denial", details: nil) }
            return .noChange
        } }
        defer { taskB.cancel(); newer.release() }
        try #require(await eventually { newer.entered && setup.busy && setup.messageScope == "newer" })
        if newerFailsFirst {
            newer.release()
            #expect(await taskB.value == false)
            #expect(setup.busy, "Older real operation is still pending")
            older.release()
            #expect(await taskA.value)
            #expect(setup.messageScope == "newer" && setup.notice == nil && setup.error?.contains("newer fixture denial") == true,
                    "An older success must not replace the latest operation failure")
        } else {
            older.release()
            #expect(await taskA.value)
            #expect(setup.busy && setup.messageScope == "newer" && setup.notice == nil,
                    "Completing an older operation cannot clear pending work or publish its stale notice")
            newer.release()
            #expect(await taskB.value)
            #expect(setup.notice == ConfigApplyOutcome.noChange.message && setup.error == nil)
        }
        #expect(!setup.busy)
    }
}
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func voiceSettingsAcknowledgementPreservesCurrentSliderDraft(_ laterEdit: Bool) async throws {
        try await VoiceSettingsDraftOwnershipHostedTests().actualAcknowledgementPreservesAnInProgressSecondSlider(laterEdit)
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func voiceSettingsRunKeepsLatestOutcomeWhileOperationsOverlap(_ newerFailsFirst: Bool) async throws {
        try await VoiceSettingsDraftOwnershipHostedTests().actualRunKeepsLatestOutcomeAndAllPendingWork(newerFailsFirst)
    }
}
#endif
