import Foundation
import PincerKit

@MainActor
func runDictationTargetChecks() {
    let target = DictationTarget(sceneID: UUID(), gatewayID: UUID(), sessionKey: "agent:main:dashboard:shared")
    let request = DictationToggleRequest(target: target, serial: 1)
    check(request.matches(target: target, paneIsActive: true), "dictation reaches its exact active composer")
    check(!request.matches(target: target, paneIsActive: false), "an unfocused split pane ignores dictation")
    check(!request.matches(
        target: DictationTarget(sceneID: UUID(), gatewayID: target.gatewayID, sessionKey: target.sessionKey),
        paneIsActive: true), "a same-key composer in another window is isolated")
    check(!request.matches(
        target: DictationTarget(sceneID: target.sceneID, gatewayID: UUID(), sessionKey: target.sessionKey),
        paneIsActive: true), "a same-key composer on another Gateway is isolated")
    check(!request.matches(
        target: DictationTarget(sceneID: target.sceneID, gatewayID: target.gatewayID, sessionKey: "agent:main:dashboard:other"),
        paneIsActive: true), "a different chat in this window is isolated")
}

@MainActor
func runDemoDictationTargetChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    gateway.reconnectIfNeeded()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }

    let key = "agent:main:dashboard:garden"
    let connected = await waitFor("demo Garden planner row") {
        gateway.state.isConnected && gateway.sessions[key]?.title == "Garden planner"
    }
    check(connected, "the demo provides its seeded Garden planner session")
    guard connected, let row = gateway.sessions[key] else { return }

    let scene = UUID()
    let target = DictationTarget(sceneID: scene, gatewayID: gateway.id, sessionKey: row.key)
    let request = DictationToggleRequest(target: target, serial: 1)
    check(request.matches(target: target, paneIsActive: true), "the seeded Garden composer matches its palette request")
    check(!request.matches(
        target: DictationTarget(sceneID: UUID(), gatewayID: gateway.id, sessionKey: row.key),
        paneIsActive: true), "the seeded Garden chat in another window stays out of this palette request")
}
