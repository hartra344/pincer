import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func runQuickCaptureChecks() {
    do {
        let standard = HotKeyShortcut.default
        check(standard.keyCode == 49 && standard.modifiers == [.control, .shift] && standard.carbonModifiers == 0x1200
              && standard.displayString == "⌃⇧Space", "default shortcut is ⌃⇧Space (\(standard.displayString))")
        let all = HotKeyShortcut(keyCode: 40, modifiers: [.command, .option, .shift, .control])
        check(all.displayString == "⌃⌥⇧⌘K", "modifiers show in Apple order (\(all.displayString))")
        check(HotKeyShortcut(storageValue: all.storageValue) == all && HotKeyShortcut(storageValue: "garbage") == nil
              && HotKeyShortcut(storageValue: "") == nil, "shortcut storage round-trips (\(all.storageValue))")
        check(HotKeyShortcut(keyCode: 40, modifiers: []).validationError != nil
              && HotKeyShortcut(keyCode: 40, modifiers: [.shift]).validationError != nil
              && HotKeyShortcut(keyCode: 96, modifiers: []).validationError == nil
              && HotKeyShortcut(keyCode: 40, modifiers: [.control, .option]).validationError == nil
              && HotKeyShortcut(keyCode: 49, modifiers: [.command]).validationError != nil,
              "shortcut validation")
        let (defaults, suite) = scratchDefaults()
        let settings = QuickCaptureSettings(defaults: defaults)
        check(settings.isEnabled && settings.shortcut == .default, "Quick Capture starts on with the default")
        settings.shortcut = all
        settings.isEnabled = false
        check(settings.activeShortcut == nil && settings.shortcut == all, "turning it off keeps the combo")
        settings.reset()
        check(settings.isEnabled && settings.shortcut == .default, "reset restores the default")
        let target = QuickCaptureTarget(gatewayId: UUID(), target: .newChat(agentId: "research"))
        settings.lastTarget = target
        check(settings.lastTarget == target && QuickCaptureTarget(storageValue: "nope|chat:x") == nil,
              "last target storage round-trips")

        // Key names, Carbon and NSEvent conversions.
        func named(_ keyCode: UInt32) -> String { HotKeyShortcut.keyName(for: keyCode) }
        check(named(36) == "↩" && named(48) == "⇥" && named(123) == "←" && named(124) == "→" && named(125) == "↓"
              && named(126) == "↑" && named(96) == "F5" && named(111) == "F12" && named(40) == "K",
              "Return, Tab, arrows and F-keys have readable names")
        check(HotKeyShortcut(keyCode: 49, carbonModifiers: 0x1200) == .default
              && HotKeyShortcut(keyCode: 40, carbonModifiers: 0x100 | 0x200 | 0x800 | 0x1000) == all
              && all.carbonModifiers == 0x1B00, "Carbon modifiers round-trip")
        check(HotKeyShortcut(keyCode: 55, carbonModifiers: 0x100) == nil && HotKeyShortcut(keyCode: 56, eventModifierFlags: 1 << 17) == nil,
              "a modifier key on its own isn't a shortcut")
        check(HotKeyShortcut(keyCode: 49, eventModifierFlags: (1 << 17) | (1 << 18) | (1 << 16)) == .default,
              "NSEvent flags map to modifiers, ignoring caps lock")
        check(HotKeyShortcut(storageValue: "49:") == HotKeyShortcut(keyCode: 49, modifiers: [])
              && HotKeyShortcut(storageValue: "49:control,hyper") == nil && HotKeyShortcut(storageValue: "x:control") == nil
              && HotKeyShortcut(storageValue: "55:command") == nil && HotKeyShortcut(storageValue: HotKeyShortcut.default.storageValue) == .default,
              "shortcut storage rejects unknown modifiers and bad key codes")
        check(HotKeyShortcut(keyCode: 49, modifiers: [.control, .option]).validationError != nil
              && HotKeyShortcut(keyCode: 96, modifiers: [.shift]).validationError == nil
              && HotKeyShortcut(keyCode: 45, modifiers: [.control, .option, .command]).validationError == nil
              && HotKeyShortcut.default.validationError == nil
              && HotKeyShortcut(keyCode: 12, modifiers: [.command]).validationError != nil,
              "⌃⌥Space and ⌘Q are taken; F-keys, ⌃⌥⌘N and the default are fine")

        // Settings: garbage loads the default; off and on again keeps the combo.
        defaults.set("garbage", forKey: QuickCaptureSettings.shortcutKey)
        check(settings.shortcut == .default && settings.isDefault, "an unreadable stored shortcut loads the default")
        settings.shortcut = all
        settings.isEnabled = false
        check(QuickCaptureSettings(defaults: defaults).activeShortcut == nil, "turning it off is saved")
        settings.isEnabled = true
        check(QuickCaptureSettings(defaults: defaults).activeShortcut == all && !settings.isDefault,
              "turning it back on restores the recorded combo")
        settings.isEnabled = false
        settings.reset()
        check(settings.activeShortcut == .default, "reset turns it back on with the default")
        settings.lastTarget = nil
        check(settings.lastTarget == nil && defaults.string(forKey: QuickCaptureSettings.lastTargetKey) == nil, "last target can be cleared")

        // Targets.
        let gatewayId = UUID()
        let chatTarget = QuickCaptureTarget(gatewayId: gatewayId, target: .chat("agent:main:dashboard:trip"))
        check(QuickCaptureTarget(storageValue: chatTarget.storageValue) == chatTarget
              && chatTarget.storageValue == "\(gatewayId.uuidString)|\(ShareTarget.chat("agent:main:dashboard:trip").storageValue)"
              && QuickCaptureTarget(storageValue: target.storageValue) == target
              && QuickCaptureTarget(storageValue: "") == nil && QuickCaptureTarget(storageValue: "\(gatewayId.uuidString)|") == nil,
              "target storage is <gateway>|<share target> (\(chatTarget.storageValue))")
        check(chatTarget.sessionKey == "agent:main:dashboard:trip" && target.sessionKey == nil, "only chat targets have a session key")
        let chatItem = PaletteItem(id: "x", title: "Japan trip", symbol: "x", section: .chats,
                                   action: .openChat(Notifier.Target(gatewayId: gatewayId, sessionKey: "agent:main:dashboard:trip")))
        let newItem = PaletteItem(id: "y", title: "New Chat with Scout", symbol: "x", section: .newChat,
                                  action: .newChat(gatewayId: gatewayId, agentId: "research"))
        check(QuickCaptureTarget(item: chatItem) == chatTarget && QuickCaptureTarget(item: newItem)?.target == .newChat(agentId: "research")
              && QuickCaptureTarget(item: PaletteItem(id: "z", title: "Settings", symbol: "x", section: .chats, action: .command("x"))) == nil,
              "palette items map to targets")

        func sessionRow(_ fields: String) -> SessionRow { SessionRow(json("{\(fields)}"))! }
        check(QuickCapture.isEligible(sessionRow(#""key":"agent:main:dashboard:trip""#))
              && !QuickCapture.isEligible(sessionRow(#""key":"agent:research:subagent:abc","spawnedBy":"agent:research:main""#))
              && !QuickCapture.isEligible(sessionRow(#""key":"agent:main:cron:disk-check""#))
              && !QuickCapture.isEligible(sessionRow(#""key":"agent:main:slash:abc""#))
              && !QuickCapture.isEligible(sessionRow(#""key":"agent:main:dashboard:old","archived":true"#)),
              "helper runs, automations, slash-command sessions and archived chats aren't targets")
        check(QuickCapture.statusText(.connected) == nil && QuickCapture.statusText(.connecting) == "Connecting…"
              && QuickCapture.statusText(.reconnecting(attempt: 1, delaySeconds: 2, reason: "x")) == "Reconnecting…"
              && QuickCapture.statusText(.failed("x")) == "Offline", "disabled rows say why")

        // Default target priority, with a Gateway that hasn't listed its sessions yet.
        let offline = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none))
        func chat(_ key: String, on gateway: UUID? = nil) -> QuickCaptureTarget {
            QuickCaptureTarget(gatewayId: gateway ?? offline.id, target: .chat(key))
        }
        let current = Notifier.Target(gatewayId: offline.id, sessionKey: "agent:main:current")
        func pick(draft: QuickCaptureTarget?, last: QuickCaptureTarget?, current: Notifier.Target?) -> QuickCaptureTarget? {
            QuickCapture.defaultTarget(draft: draft, lastTarget: last, current: current, gateways: [offline], selectedGatewayId: offline.id)
        }
        check(pick(draft: chat("draft"), last: chat("last"), current: current) == chat("draft"), "the draft's target comes first")
        check(pick(draft: nil, last: chat("last"), current: current) == chat("last"), "then the last target")
        check(pick(draft: nil, last: chat("last", on: UUID()), current: current) == chat("agent:main:current"),
              "a last target on a removed Gateway is skipped for the current chat")
        check(pick(draft: chat("gone", on: UUID()), last: nil, current: nil)
              == QuickCaptureTarget(gatewayId: offline.id, target: ShareModel.defaultTarget(remembered: nil, chats: [], agents: [], defaultAgentId: "main")),
              "then the selected Gateway's share default")
        check(!QuickCapture.isAvailable(chat("x", on: UUID()), gateways: [offline])
              && QuickCapture.defaultTarget(draft: nil, lastTarget: chat("x"), current: nil, gateways: [], selectedGatewayId: nil) == nil,
              "an unknown Gateway resolves to nothing")
        check(QuickCapture.targetItems(gateways: [offline], selectedGatewayId: offline.id, recent: [current]).isEmpty,
              "a Gateway that isn't connected offers no New Chat items")
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

/// Quick Capture's target list and send flow through `AppModel` and the demo Gateway.
@MainActor
func runQuickCaptureDemo() async {
    // A scratch suite, so concurrent check runs never see each other's saved gateways.
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let gateway = app.add(.demo(), secret: nil)
    let ready = await waitFor("demo connection") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "Quick Capture demo connected")
    guard ready else { return }
    let items = QuickCapture.targetItems(gateways: app.gateways, selectedGatewayId: app.selectedGatewayId, recent: [])
    check(!items.contains { item in
        guard case let .openChat(target) = item.action, let row = gateway.sessions[target.sessionKey] else { return false }
        return row.isSubagent || row.isAutomation || row.isArchived
    } && items.contains { $0.section == .newChat }, "target list leaves out helper runs and offers new chats")
    check(QuickCapture.targetItems(gateways: app.gateways, selectedGatewayId: app.selectedGatewayId, recent: [], query: "jptr")
        .first?.title == "Japan trip", "target search is fuzzy")

    gateway.selectedKey = "agent:main:main"
    let model = QuickCaptureModel(app: app, defaults: defaults)
    model.target = QuickCaptureTarget(gatewayId: gateway.id, target: .chat("agent:main:dashboard:trip"))
    model.prepare()
    model.text = "quick thought"
    let sent = await model.send()
    check(sent && model.text.isEmpty && gateway.selectedKey == "agent:main:main"
          && gateway.chat(for: "agent:main:dashboard:trip").items.contains { $0.role == .user && $0.plainText.contains("quick thought") },
          "sends to an existing chat without switching the main window")

    let sessionsBefore = gateway.sessions.count
    model.target = QuickCaptureTarget(gatewayId: gateway.id, target: .newChat(agentId: "research"))
    model.text = "new idea"
    let created = await model.send()
    check(created && gateway.sessions.count == sessionsBefore + 1 && gateway.selectedKey == "agent:main:main"
          && app.selectedGatewayId == gateway.id, "a new chat is created and sent to without selecting it")
    check(QuickCaptureModel(app: app, defaults: defaults).settings.lastTarget?.sessionKey?.hasPrefix("agent:research:") == true,
          "the last target is remembered as the created chat")

    let opens = app.openRequests
    model.target = QuickCaptureTarget(gatewayId: gateway.id, target: .chat("agent:main:dashboard:trip"))
    model.text = "and open it"
    let revealed = await model.send(reveal: true)
    check(revealed && gateway.selectedKey == "agent:main:dashboard:trip" && app.openRequests == opens + 1,
          "Send & Open reveals the chat")

    // ⌘↩ in Quick Capture is Send & Open; plain ↩ just sends. The main composer keeps ⌘↩ as Send.
    let commandReturn = ComposerReturnAction.resolve(shift: false, option: false, command: true, supportsSendAndOpen: true)
    check(commandReturn == .sendAndOpen, "⌘↩ in Quick Capture resolves to Send & Open")
    gateway.selectedKey = "agent:main:main"
    let opensForCommand = app.openRequests
    model.target = QuickCaptureTarget(gatewayId: gateway.id, target: .chat("agent:main:dashboard:trip"))
    model.text = "command return"
    let commandSent = await model.send(reveal: commandReturn == .sendAndOpen)
    check(commandSent && gateway.selectedKey == "agent:main:dashboard:trip" && app.openRequests == opensForCommand + 1,
          "⌘↩ in Quick Capture sends and reveals the chat")
    gateway.selectedKey = "agent:main:main"
    let plainReturn = ComposerReturnAction.resolve(shift: false, option: false, command: false, supportsSendAndOpen: true)
    let opensForPlain = app.openRequests
    model.target = QuickCaptureTarget(gatewayId: gateway.id, target: .chat("agent:main:dashboard:trip"))
    model.text = "plain return"
    let plainSent = await model.send(reveal: plainReturn == .sendAndOpen)
    check(plainReturn == .send && plainSent && gateway.selectedKey == "agent:main:main" && app.openRequests == opensForPlain,
          "↩ in Quick Capture sends without revealing")
    check(ComposerReturnAction.resolve(shift: false, option: false, command: true, supportsSendAndOpen: false) == .send,
          "⌘↩ in the main composer still just sends")
    checkComposerReturnKeySource()

    // Open in Pincer keeps the draft.
    gateway.selectedKey = "agent:main:main"
    model.prepare()
    check(model.target?.sessionKey == "agent:main:dashboard:trip", "a new panel starts at the last target")
    model.text = "not yet"
    let opensBefore = app.openRequests
    check(model.revealTarget() && gateway.selectedKey == "agent:main:dashboard:trip" && app.openRequests == opensBefore + 1
          && model.text == "not yet", "Open in Pincer reveals the chat and keeps the draft")
    model.target = QuickCaptureTarget(gatewayId: gateway.id, target: .newChat(agentId: "research"))
    check(!model.revealTarget(), "a new chat can't be revealed before it exists")
    model.text = "  \n"
    check(!model.canSend, "blank text can't be sent")

    // One Gateway: recent chats first, no duplicates, no Gateway name.
    func chat(_ store: GatewayStore, _ key: String) -> Notifier.Target { Notifier.Target(gatewayId: store.id, sessionKey: key) }
    func chatRows(_ items: [PaletteItem], on store: GatewayStore) -> [PaletteItem] {
        items.filter { if case let .openChat(target) = $0.action { target.gatewayId == store.id } else { false } }
    }
    func newChatRows(_ items: [PaletteItem], on store: GatewayStore) -> [PaletteItem] {
        items.filter { if case let .newChat(id, _) = $0.action { id == store.id } else { false } }
    }
    let papers = chat(gateway, "agent:research:dashboard:papers")
    let single = QuickCapture.targetItems(gateways: app.gateways, selectedGatewayId: gateway.id,
                                          recent: [papers, chat(gateway, "agent:main:dashboard:trip")],
                                          current: chat(gateway, "agent:main:main"))
    check(single.prefix(3).map(\.id) == [chat(gateway, "agent:main:main"), papers, chat(gateway, "agent:main:dashboard:trip")]
        .map { "chat:\($0.gatewayId.uuidString):\($0.sessionKey)" }, "the current chat, then recent chats, come first")
    check(Set(single.map(\.id)).count == single.count, "no duplicate rows")
    check(!single.contains { $0.subtitle?.contains(gateway.profile.name) == true }, "one Gateway: no Gateway name in subtitles")
    check(newChatRows(single, on: gateway).count == gateway.agents.count && single.allSatisfy(\.isEnabled),
          "a New Chat item per agent on a connected Gateway")
    check(single.firstIndex { $0.section == .newChat }! > single.lastIndex { $0.section == .chats }!, "chats before new chats")

    // Picker navigation.
    model.openPicker()
    check(model.isPickerOpen && model.highlighted(in: model.items)?.id == model.target?.itemId, "the picker highlights the current target")
    let pickerItems = model.items
    model.moveHighlight(by: 1)
    let moved = model.highlightedId
    model.moveHighlight(by: -1)
    check(moved != nil && model.highlightedId == model.target?.itemId, "↓ then ↑ comes back")
    model.query = "jptr"
    check(model.highlightedId == nil && model.highlighted(in: model.items)?.title == "Japan trip", "typing resets the highlight")
    check(model.pickHighlighted() && model.target?.sessionKey == "agent:main:dashboard:trip" && !model.isPickerOpen && model.query.isEmpty,
          "Return picks the highlighted row and closes the picker")
    check(!model.pick(PaletteItem(id: pickerItems[0].id, title: pickerItems[0].title, symbol: pickerItems[0].symbol, section: pickerItems[0].section,
                                  action: pickerItems[0].action, isEnabled: false)), "disabled rows can't be picked")
    if let pinned = model.items.first(where: { $0.shortcut == "⌘1" }) {
        check(model.pickPinned(1) && model.target?.itemId == pinned.id, "⌘1 picks the first pinned chat")
    }

    // Two Gateways plus one that never connects.
    var secondProfile = GatewayProfile.demo()
    secondProfile.name = "Second demo"
    let second = app.add(secondProfile, secret: nil)
    let offline = app.add(GatewayProfile(name: "Unreachable", url: "ws://127.0.0.1:1", authMode: .none), secret: nil)
    let secondReady = await waitFor("second demo") { second.state.isConnected && !second.sessions.isEmpty }
    check(secondReady && !offline.state.isConnected, "second demo connected")
    app.selectedGatewayId = gateway.id
    let multi = QuickCapture.targetItems(gateways: app.gateways, selectedGatewayId: gateway.id, recent: [])
    check(!chatRows(multi, on: gateway).isEmpty && chatRows(multi, on: gateway).allSatisfy { $0.subtitle?.contains(gateway.profile.name) == true }
          && !chatRows(multi, on: second).isEmpty && chatRows(multi, on: second).allSatisfy { $0.subtitle?.contains("Second demo") == true },
          "several Gateways: each chat's subtitle names its Gateway")
    check(newChatRows(multi, on: second).allSatisfy { $0.subtitle?.contains("Second demo") == true }
          && newChatRows(multi, on: second).count == second.agents.count && newChatRows(multi, on: offline).isEmpty,
          "New Chat items for each connected Gateway, none for one that isn't connected")
    check(multi.firstIndex { chatRows([$0], on: gateway).count == 1 }! < multi.firstIndex { chatRows([$0], on: second).count == 1 }!,
          "the selected Gateway's chats come first")
    check(Set(multi.map(\.id)).count == multi.count, "no duplicates across Gateways")
    let selectedBefore = app.selectedGatewayId
    model.target = QuickCaptureTarget(gatewayId: second.id, target: .chat("agent:main:dashboard:trip"))
    model.text = "to the other gateway"
    let crossSent = await model.send()
    check(crossSent && app.selectedGatewayId == selectedBefore
          && second.chat(for: "agent:main:dashboard:trip").items.contains { $0.plainText.contains("to the other gateway") }
          && !gateway.chat(for: "agent:main:dashboard:trip").items.contains { $0.plainText.contains("to the other gateway") },
          "sends to another Gateway without switching to it")
    model.target = QuickCaptureTarget(gatewayId: offline.id, target: .newChat(agentId: "main"))
    model.text = "nowhere"
    check(!model.canSend && model.connectionStatus != nil, "can't send to a Gateway that isn't connected (\(model.connectionStatus ?? "-"))")
    let offlineSent = await model.send()
    check(!offlineSent && model.text == "nowhere" && model.target?.gatewayId == offline.id
          && model.settings.lastTarget?.gatewayId == second.id, "a refused send keeps the draft and the last target")

    // The same bounded preview path backs Quick Capture's image attachment strip. Keep the
    // thumbnail local while sending the real attachment through the in-process Demo Gateway.
    let previewBytes = await Task.detached(priority: .utility) {
        attachmentThumbnailFixture(width: 1800, height: 900)
    }.value
    let preview = OutgoingAttachment(fileName: "demo-thumbnail.png", mimeType: "image/png", data: previewBytes)
    let previewLoader = AttachmentThumbnailLoader.shared
    let previewOwner = UUID()
    let previewPixels = AttachmentThumbnailLoader.targetPixelSize(points: 52, displayScale: 2)
    let previewQueued = previewLoader.request(preview, maxPixel: previewPixels, owner: previewOwner)
    model.target = QuickCaptureTarget(gatewayId: gateway.id, target: .chat("agent:main:main"))
    model.prepare()
    model.text = "Preview this image"
    model.attachments = [preview]
    let previewSent = await model.send()
    let previewReady = await waitFor("Quick Capture thumbnail", timeout: 2) {
        previewLoader.cached(preview, maxPixel: previewPixels) != nil
    }
    let previewAppearsInDemo = await waitFor("Demo attachment row", timeout: 2) {
        gateway.chat(for: "agent:main:main").items.contains { item in
            item.role == .user && item.plainText.contains("Preview this image")
                && item.blocks.contains { block in
                    switch block {
                    case let .file(file): return file.name == preview.fileName
                    case let .image(image): return image.alt == preview.fileName
                    default: return false
                    }
                }
        }
    }
    check(previewQueued && previewSent && previewAppearsInDemo && previewReady
          && previewLoader.cached(preview, maxPixel: previewPixels).map { max($0.width, $0.height) <= previewPixels } == true,
          "Quick Capture sends its real image attachment while the local thumbnail is decoded to display size")
    previewLoader.release(preview, maxPixel: previewPixels, owner: previewOwner)
}

/// Quick Capture's send flows against the mock, across two Gateways (both on the same mock).
/// The mock refuses a `chat.send` whose text has `[mock:fail-send]` and drops the connection on `[mock:drop]`.
@MainActor
func runQuickCaptureLive(url: String, token: String) async {
    // A scratch suite, so concurrent check runs never see each other's saved gateways.
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let home = app.add(GatewayProfile(name: "Mock home", url: url, authMode: .token), secret: token)
    let work = app.add(GatewayProfile(name: "Mock work", url: url, authMode: .token), secret: token)
    let ready = await waitFor("Quick Capture gateways", timeout: 25) {
        [home, work].allSatisfy { $0.state.isConnected && !$0.sessions.isEmpty }
    }
    check(ready, "two Gateways connected for Quick Capture")
    guard ready else { return }
    app.selectedGatewayId = home.id
    home.selectedKey = "agent:main:main"
    work.selectedKey = "agent:research:main"
    let nonce = String(UUID().uuidString.prefix(8))
    let model = QuickCaptureModel(app: app, defaults: defaults)
    let note = OutgoingAttachment(fileName: "note.txt", mimeType: "text/plain", data: Data("quick note".utf8))

    /// User messages with `text` in the chat's history as the Gateway has it.
    func delivered(_ store: GatewayStore, _ key: String, _ text: String) async -> Int {
        let chat = store.chat(for: key)
        _ = await waitFor("run on \(key)", timeout: 20) { !chat.isRunning }
        await chat.load(force: true)
        return chat.items.filter { $0.role == .user && $0.plainText.contains(text) }.count
    }
    func selectionUnchanged() -> Bool {
        app.selectedGatewayId == home.id && home.selectedKey == "agent:main:main" && work.selectedKey == "agent:research:main"
    }
    /// The store's session keys once its list has loaded and stopped changing, so a reload in flight
    /// can't make every session look new later.
    func baseline(_ store: GatewayStore) async -> Set<String> {
        _ = await waitFor("\(store.profile.name) sessions loaded", timeout: 10) { !store.sessions.isEmpty }
        await waitForQuiet("\(store.profile.name) session count", quiet: 0.5, timeout: 5) { store.sessions.count }
        return Set(store.sessions.keys)
    }
    /// Sessions that appeared since `before`; when none are expected it just gives `sessions.changed` time to arrive.
    func created(on store: GatewayStore, since before: Set<String>, expected: Bool = true) async -> [String] {
        if expected {
            _ = await waitFor("sessions.changed", timeout: 3) { Set(store.sessions.keys).count > before.count }
        } else {
            // Negative window: a stray sessions.changed would show up within this time.
            try? await Task.sleep(for: .seconds(1))
        }
        return Array(Set(store.sessions.keys).subtracting(before))
    }

    // The list: both Gateways, no helper runs or automations.
    let items = QuickCapture.targetItems(gateways: app.gateways, selectedGatewayId: app.selectedGatewayId, recent: [])
    let keys = items.compactMap { item -> String? in if case let .openChat(target) = item.action { target.sessionKey } else { nil } }
    check(!keys.isEmpty && !keys.contains { $0.contains(":cron:") || $0.contains(":subagent:") } && items.allSatisfy(\.isEnabled),
          "live target list leaves out automations and helper runs")
    check(items.filter { $0.section == .newChat }.count == home.agents.count + work.agents.count
          && items.contains { $0.subtitle?.contains("Mock work") == true }, "live target list covers both Gateways")

    // 9. An existing chat: one chat.send, no sessions.create, nothing selected.
    let trip = "agent:main:dashboard:trip"
    var workKeys = await baseline(work)
    let opens = app.openRequests
    model.prepare()
    model.target = QuickCaptureTarget(gatewayId: work.id, target: .chat(trip))
    model.text = "qc existing \(nonce)"
    model.attachments = [note]
    let sentExisting = await model.send()
    check(sentExisting && model.text.isEmpty && model.attachments.isEmpty && model.error == nil && model.target == nil,
          "existing chat: send succeeds and clears the draft")
    let createdByExisting = await created(on: work, since: workKeys, expected: false)
    let existingCount = await delivered(work, trip, "qc existing \(nonce)")
    check(existingCount == 1 && createdByExisting.isEmpty, "existing chat: exactly one message and no new session (\(existingCount), \(createdByExisting))")
    check(selectionUnchanged() && app.openRequests == opens, "existing chat: the main window's selection is unchanged")
    check(model.settings.lastTarget == QuickCaptureTarget(gatewayId: work.id, target: .chat(trip))
          && defaults.string(forKey: QuickCaptureSettings.lastTargetKey) == "\(work.id.uuidString)|\(ShareTarget.chat(trip).storageValue)",
          "14. the last target is saved as <gateway>|<target>")
    let fresh = QuickCaptureModel(app: app, defaults: defaults)
    fresh.prepare()
    check(fresh.target == QuickCaptureTarget(gatewayId: work.id, target: .chat(trip)), "14. a new model starts at the last target")

    // 10. A new chat: sessions.create, then chat.send to the new key; nothing selected.
    workKeys = await baseline(work)
    model.target = QuickCaptureTarget(gatewayId: work.id, target: .newChat(agentId: "research"))
    model.text = "qc new \(nonce)"
    let sentNew = await model.send()
    let newKeys = await created(on: work, since: workKeys)
    check(sentNew && newKeys.count == 1 && newKeys.first?.hasPrefix("agent:research:") == true,
          "new chat: exactly one session created (\(newKeys))")
    if let newKey = newKeys.first {
        let newCount = await delivered(work, newKey, "qc new \(nonce)")
        check(newCount == 1, "new chat: the message went to the created chat (\(newCount))")
    }
    check(selectionUnchanged() && app.openRequests == opens, "new chat: selectedKey and selectedGatewayId unchanged")
    check(model.settings.lastTarget == newKeys.first.map { QuickCaptureTarget(gatewayId: work.id, target: .chat($0)) },
          "new chat: the last target is the created chat (\(model.settings.lastTarget?.storageValue ?? "nil"))")

    // 11. Reveal: the created chat on the other Gateway is opened.
    workKeys = await baseline(work)
    model.target = QuickCaptureTarget(gatewayId: work.id, target: .newChat(agentId: "main"))
    model.text = "qc reveal \(nonce)"
    let revealed = await model.send(reveal: true)
    let revealedKeys = await created(on: work, since: workKeys)
    check(revealed && revealedKeys.count == 1 && app.selectedGatewayId == work.id && work.selectedKey == revealedKeys.first
          && app.openRequests == opens + 1 && app.history.current?.sessionKey == revealedKeys.first,
          "reveal: the new chat's Gateway and chat are selected")
    app.selectedGatewayId = home.id
    work.selectedKey = "agent:research:main"

    // 12. A refused send keeps everything.
    let lastBefore = model.settings.lastTarget
    model.target = QuickCaptureTarget(gatewayId: home.id, target: .chat(trip))
    model.text = "qc refused [mock:fail-send] \(nonce)"
    model.attachments = [note]
    let refused = await model.send()
    check(!refused && model.text == "qc refused [mock:fail-send] \(nonce)" && model.attachments == [note]
          && model.target == QuickCaptureTarget(gatewayId: home.id, target: .chat(trip)) && !model.isSending,
          "refused send: returns false and keeps the text, attachments and target")
    check(model.error?.hasPrefix("Couldn’t send:") == true, "refused send: an error is shown (\(model.error ?? "none"))")
    check(model.settings.lastTarget == lastBefore, "refused send: the last target isn't updated")
    check(!home.chat(for: trip).items.contains { $0.plainText.contains("qc refused") }, "refused send: no stray message in the chat")
    model.text = "qc retried \(nonce)"
    let retried = await model.send()
    check(retried && model.error == nil && model.settings.lastTarget == QuickCaptureTarget(gatewayId: home.id, target: .chat(trip)),
          "refused send: a retry goes through and clears the error")

    // 13. sessions.create succeeds but chat.send fails: the retry goes to the created chat.
    var homeKeys = Set(home.sessions.keys)
    let lastBeforeCreate = model.settings.lastTarget
    model.target = QuickCaptureTarget(gatewayId: home.id, target: .newChat(agentId: "research"))
    model.text = "qc half [mock:fail-send] \(nonce)"
    let half = await model.send()
    let halfKeys = await created(on: home, since: homeKeys)
    check(!half && halfKeys.count == 1 && model.target == halfKeys.first.map { QuickCaptureTarget(gatewayId: home.id, target: .chat($0)) }
          && model.text.contains("qc half") && model.error != nil && model.settings.lastTarget == lastBeforeCreate,
          "create ok, send failed: the target becomes the created chat (\(halfKeys))")
    check(selectionUnchanged(), "create ok, send failed: nothing selected")
    homeKeys = Set(home.sessions.keys)
    model.text = "qc half retried \(nonce)"
    let halfRetried = await model.send()
    let extraKeys = await created(on: home, since: homeKeys, expected: false)
    if let halfKey = halfKeys.first {
        let halfCount = await delivered(home, halfKey, "qc half retried \(nonce)")
        check(halfRetried && extraKeys.isEmpty && halfCount == 1
              && model.settings.lastTarget == QuickCaptureTarget(gatewayId: home.id, target: .chat(halfKey)),
              "create ok, send failed: the retry doesn't create a second chat")

        // A chat archived elsewhere drops out of the list and isn't the default any more.
        await home.patch(halfKey, ["archived": true])
        let archived = await waitFor("archive") { home.sessions[halfKey]?.isArchived == true }
        let listed = QuickCapture.targetItems(gateways: app.gateways, selectedGatewayId: home.id, recent: [])
        check(archived && !listed.contains { $0.id == "chat:\(home.id.uuidString):\(halfKey)" }, "archived chats leave the list")
        let reopened = QuickCaptureModel(app: app, defaults: defaults)
        reopened.prepare()
        check(reopened.target == QuickCaptureTarget(gatewayId: home.id, target: .chat("agent:main:main")),
              "an archived last target falls back to the current chat (\(reopened.target?.storageValue ?? "nil"))")
    }

    // 12. The connection drops mid-send: the draft stays, rows go disabled, and Send comes back on reconnect.
    model.target = QuickCaptureTarget(gatewayId: work.id, target: .chat(trip))
    model.text = "qc dropped [mock:drop] \(nonce)"
    model.attachments = [note]
    let dropped = await model.send()
    check(!dropped && model.text.contains("qc dropped") && model.attachments == [note] && model.error != nil,
          "dropped connection: the draft is kept and an error shown (\(model.error ?? "none"))")
    let lost = await waitFor("connection lost", timeout: 5) { !work.state.isConnected }
    let offlineItems = model.items
    let workRows = offlineItems.filter { if case let .openChat(target) = $0.action { target.gatewayId == work.id } else { false } }
    check(lost && !model.canSend && model.connectionStatus != nil, "dropped connection: Send is disabled (\(model.connectionStatus ?? "-"))")
    check(!workRows.isEmpty && workRows.allSatisfy { !$0.isEnabled && $0.subtitle?.contains("Mock work") == true }
          && !offlineItems.contains { if case let .newChat(id, _) = $0.action { id == work.id } else { false } }
          && offlineItems.contains { $0.isEnabled },
          "dropped connection: that Gateway's chats are disabled and its New Chat items gone")
    check(workRows.first.map { !model.pick($0) } ?? false, "a disabled row can't be picked")
    model.openPicker()
    for _ in 0..<offlineItems.count { model.moveHighlight(by: 1) }
    check(model.highlighted(in: model.items)?.isEnabled == true, "↑/↓ skip disabled rows")
    model.closePicker()
    let back = await waitFor("reconnect", timeout: 20) { work.state.isConnected }
    check(back && model.canSend && model.target?.gatewayId == work.id, "Send is enabled again once the Gateway reconnects")
    model.text = "qc after drop \(nonce)"
    let afterDrop = await model.send()
    let afterDropCount = await delivered(work, trip, "qc after drop \(nonce)")
    check(afterDrop && afterDropCount == 1, "a send after reconnecting goes through (\(afterDropCount))")
    check(selectionUnchanged(), "no send changed the main window's selection")
}

/// Return from a hardware keyboard sends on every platform; the on-screen keyboard's Return stays a newline (#567).
@MainActor
private func checkComposerReturnKeySource() {
    func resolve(_ source: ComposerReturnKey.Source, marked: Bool = false, shift: Bool = false, canSubmit: Bool = true) -> ComposerReturnKey {
        ComposerReturnKey.resolve(
            source: source, hasMarkedText: marked, shift: shift, option: false, command: false,
            supportsSendAndOpen: false, canSubmit: canSubmit)
    }
    check(resolve(.hardware) == .send, "hardware-keyboard ↩ sends")
    check(resolve(.hardware, shift: true) == .newline, "hardware-keyboard ⇧↩ inserts a newline")
    check(resolve(.software) == .system && resolve(.software, canSubmit: false) == .system,
          "the on-screen keyboard's Return is left to the text system (a newline)")
    check(resolve(.hardware, marked: true) == .system, "↩ while composing marked text commits the candidate")
    check(resolve(.hardware, canSubmit: false) == .ignore, "↩ with an empty draft neither sends nor inserts a newline")
}
