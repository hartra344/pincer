import PincerKit
import Foundation

@MainActor
func runShortcutTipsChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let shortcuts = ShortcutStore(defaults: defaults)
    shortcuts.set(KeyCombo("p", [.control, .option]), for: .commandPalette)
    shortcuts.set(KeyCombo("f", [.control, .option]), for: .findInChat)
    let custom = SetupTips.tips(iOS: false, shortcuts: shortcuts)
    check(custom.first { $0.tip.id == "palette" }?.text.contains("⌃⌥P") == true
          && custom.first { $0.tip.id == "find" }?.text.contains("⌃⌥F") == true,
          "tips show current customized palette and find shortcuts")
    shortcuts.set(nil, for: .commandPalette)
    shortcuts.set(nil, for: .findInChat)
    let cleared = SetupTips.tips(iOS: false, shortcuts: shortcuts)
    check(cleared.allSatisfy { !$0.text.contains("⌘K") && !$0.text.contains("⌘F") },
          "cleared shortcuts are not advertised in tips")
    let phone = SetupTips.tips(iOS: true, iPhone: true, shortcuts: shortcuts)
    check(phone.allSatisfy { !$0.tip.usesKeyboard && !$0.text.contains("⌘") },
          "iPhone retains touch-only tips")
    check(phone.first { $0.tip.id == "thinking" }?.text
          == "Ask for deeper reasoning with /think. Expand a thinking section to read it.",
          "the compact thinking tip separates deeper reasoning from reading a thinking section")
}

@MainActor
func runDemoShortcutTips() async {
    let shortcuts = ShortcutStore.shared
    let oldPalette = shortcuts.combo(for: .commandPalette)
    let oldFind = shortcuts.combo(for: .findInChat)
    let capture = QuickCaptureSettings()
    let oldEnabled = capture.defaults.object(forKey: QuickCaptureSettings.enabledKey)
    let oldCapture = capture.defaults.object(forKey: QuickCaptureSettings.shortcutKey)
    defer {
        shortcuts.set(oldPalette, for: .commandPalette)
        shortcuts.set(oldFind, for: .findInChat)
        capture.defaults.set(oldEnabled, forKey: QuickCaptureSettings.enabledKey)
        capture.defaults.set(oldCapture, forKey: QuickCaptureSettings.shortcutKey)
    }
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    defer { gateway.stop() }
    let ready = await waitFor("demo shortcut tips connected") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "demo shortcut tips connected")
    guard ready else { return }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let tips = SetupTips.tips(iOS: true, iPhone: true, shortcuts: shortcuts)
    check(tips.first { $0.tip.id == "thinking" }?.text
          == "Ask for deeper reasoning with /think. Expand a thinking section to read it.",
          "the connected demo's compact tips retain the two-sentence thinking guidance")
    shortcuts.set(KeyCombo("p", [.control, .option]), for: .commandPalette)
    shortcuts.set(KeyCombo("f", [.control, .option]), for: .findInChat)
    capture.isEnabled = true
    capture.shortcut = HotKeyShortcut(keyCode: 12, modifiers: [.control, .option])
    let before = chat.entries.count
    await chat.send("hello")
    let customDone = await waitFor("customized demo shortcut reply", timeout: 30) { !chat.isRunning && chat.entries.count > before + 1 }
    if customDone, case let .assistant(turn)? = chat.entries.last {
        check(turn.body.contains("⌃⌥P") && turn.body.contains("⌃⌥F") && turn.body.contains("⌃⌥Q")
              && !turn.body.contains("⌘K") && !turn.body.contains("⌘F"),
              "actual demo reply uses the current shortcut snapshot")
    } else { check(false, "customized demo shortcut reply completed") }
    shortcuts.set(nil, for: .commandPalette)
    shortcuts.set(nil, for: .findInChat)
    capture.isEnabled = false
    let second = chat.entries.count
    await chat.send("hello again")
    let clearedDone = await waitFor("cleared demo shortcut reply", timeout: 30) { !chat.isRunning && chat.entries.count > second + 1 }
    if clearedDone, case let .assistant(turn)? = chat.entries.last {
        check(!turn.body.contains("⌘K") && !turn.body.contains("⌘F")
              && !turn.body.contains("⌃⌥P") && !turn.body.contains("⌃⌥F") && !turn.body.contains("⌃⌥Q")
              && !turn.body.contains("⌃⇧Space")
              && turn.body.contains("command palette") && turn.body.contains("Japan trip"),
              "actual next demo reply drops cleared shortcuts and retains action guidance")
    } else { check(false, "cleared demo shortcut reply completed") }
}
