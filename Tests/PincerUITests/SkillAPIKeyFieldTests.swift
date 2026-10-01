#if os(iOS)
import Observation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

/// #505: exercise the actual Settings skill page. A raw password SecureField has the wrong
/// UIKit content type even though masking looks identical to the API-key editor.
@MainActor
struct SkillAPIKeyFieldProbe {
    @Observable final class EditorState {
        var text = ""
        var disabled = true
        var submissions: [String] = []
    }

    struct ControlledEditor: View {
        @Bindable var state: EditorState
        var body: some View {
            APIKeyField(title: "New API key", prompt: "Paste API key", text: self.$state.text,
                        onSubmit: { self.state.submissions.append(self.state.text) })
                .disabled(self.state.disabled)
        }
    }

    static func fields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap { Self.fields(in: $0) }
    }

    /// SwiftPM's unhosted iOS test process has no UIApplication to dispatch sendActions.
    /// Invoke the field's registered editing targets directly to exercise the same binding path.
    static func editingChanged(_ field: UITextField) -> Int {
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

    func disabledStateAndBindingReachNativeFieldAfterUpdates() async throws {
        let state = EditorState()
        let host = UIHostingController(rootView: ControlledEditor(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let loaded = await eventually {
            host.view.layoutIfNeeded()
            return !Self.fields(in: host.view).isEmpty
        }
        #expect(loaded)
        let field = try #require(Self.fields(in: host.view).first)
        #expect(!field.isEnabled && !field.becomeFirstResponder(), "a read-only or busy skill cannot edit its key")
        #expect(field.isSecureTextEntry && field.textContentType == .oneTimeCode && field.passwordRules == nil)
        state.text = "server-updated-key"
        state.disabled = false
        let enabled = await eventually { field.isEnabled && field.text == "server-updated-key" }
        #expect(enabled, "updates preserve the binding and re-enable native input")
        field.text = "sk-pasted_MiXeD+/=:@."
        #expect(Self.editingChanged(field) > 0, "the field wires an editing-changed binding target")
        #expect(state.text == "sk-pasted_MiXeD+/=:@.")
        _ = field.delegate?.textFieldShouldReturn?(field)
        #expect(state.submissions == [state.text])
        state.disabled = true
        let disabledAgain = await eventually { !field.isEnabled }
        #expect(disabledAgain, "later read-only/busy changes disable the existing field")
    }

    func skillKeyUsesNonPasswordInputAndReturnSaves() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.start()
        defer { gateway.stop() }
        let connected = await eventually(timeout: .seconds(10)) { gateway.state.isConnected }
        #expect(connected)
        guard connected else { return }
        await gateway.skills.load(agentId: nil)
        #expect(gateway.skills.skill(key: "notion")?.apiKeyIsSet == false)
        let host = UIHostingController(rootView: SkillDetailPage(skillKey: "notion")
            .environment(gateway).environment(SettingsNavigator(destination: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 1800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let loaded = await eventually(timeout: .seconds(10)) {
            host.view.layoutIfNeeded()
            return Self.fields(in: host.view).contains { $0.isSecureTextEntry }
        }
        #expect(loaded)
        let field = try #require(Self.fields(in: host.view).first { $0.isSecureTextEntry })
        #expect(field.textContentType == .oneTimeCode, "API keys must not request Passwords/Strong Password autofill")
        #expect(field.passwordRules == nil)
        #expect(field.autocapitalizationType == .none && field.autocorrectionType == .no)
        #expect(field.keyboardType == .asciiCapable && field.returnKeyType == .done)

        // Simulate a paste through UIKit's editing event, then the keyboard Return path. This
        // verifies the hosted field's binding and submit action, rather than only its traits.
        let key = "sk-test_MiXeD-123+/=:@."
        field.text = key
        #expect(Self.editingChanged(field) > 0, "the hosted skill editor wires the pasted key binding")
        await Task.yield()
        #expect(field.text == key && field.isSecureTextEntry, "pasted punctuation/case stays masked and unchanged")
        _ = field.delegate?.textFieldShouldReturn?(field)
        let saved = await eventually(timeout: .seconds(10)) {
            gateway.skills.skill(key: "notion")?.apiKeyIsSet == true && field.text?.isEmpty == true
        }
        #expect(saved, "Return saves the skill key and clears the editor")
        if let skill = gateway.skills.skill(key: "notion") { _ = await gateway.skills.setApiKey(skill, "") }
    }
}

// Keep these regressions in the hosted UIKit suite selected by the existing iOS CI lane.
extension TranscriptUIKitHostedTests {
    @Test func skillAPIKeyDisabledStateAndBinding() async throws {
        try await SkillAPIKeyFieldProbe().disabledStateAndBindingReachNativeFieldAfterUpdates()
    }

    @Test func skillAPIKeyAvoidsPasswordsAndSavesOnReturn() async throws {
        try await SkillAPIKeyFieldProbe().skillKeyUsesNonPasswordInputAndReturnSaves()
    }
}
#endif
