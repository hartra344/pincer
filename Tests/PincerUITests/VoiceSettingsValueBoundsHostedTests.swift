#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Gateway voice settings value bounds", .serialized)
struct VoiceSettingsValueBoundsHostedTests {
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func actualGatewayValuesRenderWithoutTrapping(_ oversized: Bool) async throws {
        let settings: JSONValue = ["stability": .number(oversized ? 1e308 : 0.5), "similarityBoost": 0.75,
                                   "style": 0, "speed": 1, "useSpeakerBoost": true]
        var writes = 0
        let model = GatewayVoiceModel(request: { method, _ in
            switch method {
            case "config.get": return ["config": ["tts": ["providers": ["elevenlabs": ["voiceSettings": settings]]]], "hash": "bounds"]
            case "tts.status": return ["provider": "elevenlabs", "enabled": false, "providerStates": []]
            case "tts.providers": return ["providers": []]
            case "tts.personas": return ["personas": []]
            case "secrets.store.list": return ["entries": []]
            case "config.patch": writes += 1; return ["ok": true]
            default: Issue.record("Unexpected actual voice bounds RPC: \(method)"); return [:]
            }
        })
        await model.refresh()
        try #require(model.setups["elevenlabs"]?.voiceSettings != nil,
                     "Actual config.get must install the provider's voice settings before rendering")
        let host = UIHostingController(rootView: NavigationStack { Form {
            VoiceSetupSettingsSection(model: model, setup: VoiceSetupController(), provider: "elevenlabs",
                                      editable: true, initialExpanded: true)
        } })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func sliders(_ view: UIView) -> [UISlider] {
            (view as? UISlider).map { [$0] } ?? view.subviews.flatMap(sliders)
        }
        try #require(await eventually {
            window.layoutIfNeeded()
            return sliders(window).count == 4
        }, "Actual expanded voice section must render four native sliders")
        for _ in 0..<4 { await Task.yield() }; window.layoutIfNeeded()
        #expect(sliders(window).allSatisfy { $0.value.isFinite && (0...1).contains($0.value) })
        #expect(writes == 0, "Opening malformed voice settings must never write normalization to the Gateway")
    }
}
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func gatewayVoiceSettingsValuesCannotTrapTheActualSection(_ oversized: Bool) async throws {
        try await VoiceSettingsValueBoundsHostedTests().actualGatewayValuesRenderWithoutTrapping(oversized)
    }
}
#endif
