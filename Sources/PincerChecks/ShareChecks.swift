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

/// A throwaway defaults suite, so share checks never touch the real App Group or app defaults.
func scratchDefaults() -> (UserDefaults, String) {
    let name = "pincer.checks.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

func pngData(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

@MainActor
func runShareChecks() async {
    // Upload limits and chat.send params (shared with the composer).
    let defaultLimits = UploadLimits(hello: nil)
    check(defaultLimits.imageBytes == 5_000_000 && defaultLimits.fileBytes == 10_000_000, "default upload limits")
    let tight = UploadLimits(maxPayload: 1_000_000, maxImageBytes: 5_000_000, maxAttachmentBytes: 20_000_000)
    check(tight.imageBytes == 700_000 && tight.fileBytes == 700_000, "limits stay under 70% of maxPayload")
    let file = OutgoingAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8))
    let sendParams = ChatSendRequest.params(sessionKey: "agent:research:main", agentId: "research", message: "look",
                                            idempotencyKey: "k1", attachments: [file])
    check(sendParams["agentId"] == nil && sendParams["sessionKey"] == "agent:research:main" && sendParams["message"] == "look"
          && sendParams["idempotencyKey"] == "k1", "chat.send params for an agent-scoped key")
    check(sendParams["attachments"]?.array?.first == ["type": "file", "mimeType": "text/plain", "fileName": "notes.txt",
                                                      "content": .string(Data("hi".utf8).base64EncodedString()), "sizeBytes": 2],
          "chat.send attachment shape")
    let bareKey = ChatSendRequest.params(sessionKey: "main", agentId: "main", message: "", idempotencyKey: "k2", attachments: [])
    check(bareKey["agentId"] == "main" && bareKey["attachments"] == nil, "agentId sent for keys without an agent")

    // Message composition.
    let article = URL(string: "https://example.com/article")!
    let content = SharedContent(texts: ["Great read", "  "], urls: [article, URL(string: "https://example.com/b")!])
    check(content.message(note: "  summarize this ") == "summarize this\n\nGreat read\n\nhttps://example.com/article\nhttps://example.com/b",
          "note, then text, then links (got \(content.message(note: "  summarize this ").debugDescription))")
    let safari = SharedContent(texts: ["Title — https://example.com/article"], urls: [article, article])
    check(safari.message(note: "") == "Title — https://example.com/article", "links already in the text aren't repeated")
    check(SharedContent(urls: [article]).message(note: "see https://example.com/article") == "see https://example.com/article",
          "links already in the note aren't repeated")
    check(SharedContent(texts: ["same"]).message(note: "same") == "same", "duplicate text collapses")
    check(SharedContent().isEmpty && SharedContent().message(note: " ") == "", "empty share")

    // Sizing attachments.
    let bigPNG = pngData(width: 1600, height: 1200)
    check(bigPNG.count < 100_000, "test image is small on disk (\(bigPNG.count) bytes)")
    let files = SharedContent(files: [
        SharedFile(name: "photo.png", typeIdentifier: UTType.png.identifier, data: bigPNG),
        SharedFile(name: "report.pdf", typeIdentifier: UTType.pdf.identifier, data: Data(count: 2_000)),
        SharedFile(name: "huge.zip", typeIdentifier: UTType.zip.identifier, data: Data(count: 800_000)),
        SharedFile(name: "broken.jpg", typeIdentifier: UTType.jpeg.identifier, data: Data("nope".utf8)),
        SharedFile(name: "blob", typeIdentifier: nil, data: Data(count: 10)),
    ])
    let sized = files.attachments(limits: tight)
    check(sized.attachments.map(\.fileName) == ["photo.png", "report.pdf", "blob"], "fitting files attached (got \(sized.attachments.map(\.fileName)))")
    check(sized.attachments.first?.isImage == true && (sized.attachments.first?.data.count ?? .max) <= tight.imageBytes, "images sized for the Gateway")
    check(sized.attachments.dropFirst().first?.mimeType == "application/pdf" && sized.attachments.last?.mimeType == "application/octet-stream",
          "MIME types from the file type")
    check(sized.problems.count == 2 && sized.problems[0].hasPrefix("huge.zip is larger") && sized.problems[1].contains("broken.jpg"),
          "oversized and unreadable files reported (\(sized.problems))")

    // Reading the share sheet's item providers.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-share-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let textFile = folder.appendingPathComponent("notes.md")
    try? Data("# Notes".utf8).write(to: textFile)
    let largeFile = folder.appendingPathComponent("large.bin")
    try? Data(count: 200_000).write(to: largeFile)
    let item = NSExtensionItem()
    item.attributedContentText = NSAttributedString(string: "From the host")
    let imageProvider = NSItemProvider(item: bigPNG as NSData, typeIdentifier: UTType.png.identifier)
    imageProvider.suggestedName = "Screenshot"
    item.attachments = [
        NSItemProvider(item: "Some selected text" as NSString, typeIdentifier: UTType.plainText.identifier),
        NSItemProvider(object: article as NSURL),
        NSItemProvider(contentsOf: textFile)!,
        imageProvider,
        NSItemProvider(contentsOf: folder)!,
        NSItemProvider(contentsOf: largeFile)!,
    ]
    let loaded = await SharedContentLoader.load([item], maxFileBytes: 100_000)
    check(loaded.texts == ["From the host", "Some selected text"], "host text and plain text (\(loaded.texts))")
    check(loaded.urls == [article], "web URL kept as a link")
    check(loaded.files.map(\.name) == ["notes.md", "Screenshot.png"], "file and image loaded (\(loaded.files.map(\.name)))")
    check(loaded.files.first?.data == Data("# Notes".utf8), "file contents read")
    check(loaded.files.last?.isImage == true && loaded.files.last?.data == bigPNG, "image data kept for sizing later")
    check(loaded.problems.count == 2 && loaded.problems[0].contains("folder") && loaded.problems[1].contains("large.bin"),
          "folders and oversized files reported (\(loaded.problems))")

    // Shared storage.
    let (shared, sharedName) = scratchDefaults()
    let (legacy, legacyName) = scratchDefaults()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: sharedName)
        UserDefaults.standard.removePersistentDomain(forName: legacyName)
    }
    let home = GatewayProfile(name: "Home", url: "wss://home.tail1234.ts.net", authMode: .token)
    GatewayProfileStore.save([home], to: legacy)
    check(GatewayProfileStore.load(from: shared, legacy: legacy).map(\.id) == [home.id], "profiles saved before the App Group migrate")
    legacy.removeObject(forKey: "pincer.gatewayProfiles.v1")
    check(GatewayProfileStore.load(from: shared, legacy: legacy).map(\.id) == [home.id], "migrated profiles live in the App Group")
    GatewayProfileStore.save([], to: shared)
    GatewayProfileStore.save([home], to: legacy)
    check(GatewayProfileStore.load(from: shared, legacy: legacy).isEmpty, "an emptied shared list isn't re-migrated")
    check(SharedContainer.keychainAccounts(for: [home]) == ["device.ed25519", "secret.\(home.id.uuidString)", "deviceToken.\(home.id.uuidString)"],
          "device key, secret and device token are shared")
    check(SharedContainer.appGroupId == nil && SharedContainer.keychainAccessGroup == nil, "SwiftPM builds have no shared container")
    let paired = DeviceIdentity.loadOrCreate()
    check(DeviceIdentity.loadExisting()?.deviceId == paired.deviceId, "extension reuses the paired identity")

    // Targets.
    for target in [ShareTarget.chat("agent:main:discord:channel:1"), .newChat(agentId: "research")] {
        check(ShareTarget(storageValue: target.storageValue) == target, "target round-trips (\(target.storageValue))")
    }
    check(ShareTarget(storageValue: "junk") == nil, "unknown stored target ignored")
    let rows = [
        #"{"key":"agent:main:main","lastActivityAt":100}"#,
        #"{"key":"agent:main:dashboard:new","lastActivityAt":300}"#,
        #"{"key":"agent:research:main","pinned":true,"lastActivityAt":50}"#,
        #"{"key":"agent:main:subagent:x","lastActivityAt":900}"#,
        #"{"key":"agent:main:cron:job1","lastActivityAt":800}"#,
        #"{"key":"agent:main:old","archived":true,"lastActivityAt":700}"#,
    ].compactMap { SessionRow(json($0)) }
    let chats = ShareModel.shareableChats(rows)
    check(chats.map(\.key) == ["agent:research:main", "agent:main:dashboard:new", "agent:main:main"],
          "shareable chats: pinned, then recent; no helpers, automations or archived (\(chats.map(\.key)))")
    let agents = [AgentSummary(id: "main", name: "Main"), AgentSummary(id: "research", name: "Research")]
    check(ShareModel.defaultTarget(remembered: .chat("agent:main:dashboard:new"), chats: chats, agents: agents, defaultAgentId: "main")
          == .chat("agent:main:dashboard:new"), "last chat reused")
    check(ShareModel.defaultTarget(remembered: .chat("agent:gone:main"), chats: chats, agents: agents, defaultAgentId: "main")
          == .chat("agent:main:main"), "missing chat falls back to the default agent's main chat")
    check(ShareModel.defaultTarget(remembered: .newChat(agentId: "research"), chats: chats, agents: agents, defaultAgentId: "main")
          == .newChat(agentId: "research"), "last new-chat agent reused")
    check(ShareModel.defaultTarget(remembered: .newChat(agentId: "gone"), chats: [], agents: agents, defaultAgentId: "main")
          == .newChat(agentId: "main"), "no chats → new chat with the default agent")

    // Setup states.
    let (setup, setupName) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: setupName) }
    if case .unavailable = ShareModel(profiles: [], identity: paired, defaults: setup).phase {} else { check(false, "no gateways → unavailable") }
    if case let .unavailable(message) = ShareModel(profiles: [home], identity: nil, defaults: setup).phase {
        check(message.contains("Open Pincer"), "no device key yet → asks to open the app")
    } else {
        check(false, "no device key yet → unavailable")
    }
    let other = GatewayProfile(name: "Work", url: "wss://work.example.com", authMode: .token)
    setup.set(other.id.uuidString, forKey: AppModel.selectedGatewayKey)
    check(ShareModel(profiles: [home, other], identity: paired, defaults: setup).profileId == other.id, "starts on the app's selected gateway")
    setup.set(home.id.uuidString, forKey: ShareModel.lastGatewayKey)
    check(ShareModel(profiles: [home, other], identity: paired, defaults: setup).profileId == home.id, "prefers the last gateway shared to")

    // End to end against the built-in demo gateway.
    let demo = GatewayProfile.demo()
    let model = ShareModel(profiles: [demo], identity: paired, defaults: setup)
    model.setContent(SharedContent(texts: ["Selected text"], urls: [article], files: [
        SharedFile(name: "photo.png", typeIdentifier: UTType.png.identifier, data: bigPNG),
        SharedFile(name: "notes.md", typeIdentifier: "net.daringfireball.markdown", data: Data("# Notes".utf8)),
    ]))
    check(!model.canSend, "can't send before connecting")
    model.connect()
    let ready = await waitFor("share model ready with prepared attachments") {
        model.phase == .ready && !model.isPreparingAttachments
    }
    check(ready, "share model connects to the demo gateway (\(model.phase))")
    guard ready else { model.disconnect(); return }
    check(!model.chats.isEmpty && !model.chats.contains { $0.isSubagent }, "chats listed (\(model.chats.count))")
    check(model.agents.count >= 3 && model.target == .chat("agent:main:main"), "defaults to the main chat (\(String(describing: model.target)))")
    check(model.attachments.count == 2 && model.attachmentProblems.isEmpty, "attachments prepared with the Gateway's limits")
    model.note = "Summarize"
    check(model.messageText == "Summarize\n\nSelected text\n\nhttps://example.com/article", "message text")
    model.target = .newChat(agentId: "research")
    let sent = await model.send()
    check(sent && model.phase == .sent && model.sendError == nil, "sent to a new chat (\(model.sendError ?? ""))")
    check(setup.string(forKey: ShareModel.lastTargetKey(demo.id)) == "new:research", "target remembered for next time")
    model.disconnect()

    let again = ShareModel(profiles: [demo], identity: paired, defaults: setup)
    again.connect()
    _ = await waitFor("second share ready") { again.phase == .ready }
    check(again.target == .newChat(agentId: "research"), "next share starts on the remembered target")
    let picked = again.chats.first { $0.key != "agent:main:main" }!.key
    again.target = .chat(picked)
    await again.refreshTargets()
    check(again.target == .chat(picked), "a reconnect keeps the chat the user picked (\(String(describing: again.target)))")
    again.target = .chat("agent:gone:main")
    again.setContent(SharedContent(texts: ["hello"]))
    let failed = await again.send()
    check(!failed && again.phase == .ready && again.sendError?.contains("unknown session") == true,
          "send errors surface and allow retry (\(again.sendError ?? "nil"))")
    again.disconnect()
}

/// The Share extension's path over a real socket: same paired device, new chat, attachments.
@MainActor
func runLiveShare(profile: GatewayProfile, gateway: GatewayStore) async {
    let (defaults, name) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let model = ShareModel(profiles: [profile], identity: DeviceIdentity.loadExisting(), defaults: defaults)
    model.connect()
    let ready = await waitFor("share ready", timeout: 20) { model.phase == .ready }
    check(ready, "share extension connects as the paired device (\(model.phase))")
    guard ready else { model.disconnect(); return }
    check(!model.chats.isEmpty && model.target != nil, "share targets listed (\(model.chats.count))")
    let before = Set(gateway.sessions.keys)
    let marker = "shared-\(UUID().uuidString.prefix(8))"
    model.note = marker
    model.setContent(SharedContent(urls: [URL(string: "https://example.com/paper.pdf")!], files: [
        SharedFile(name: "chart.png", typeIdentifier: UTType.png.identifier, data: pngData(width: 64, height: 64)),
        SharedFile(name: "notes.txt", typeIdentifier: UTType.plainText.identifier, data: Data("notes".utf8)),
    ]))
    model.target = .newChat(agentId: "research")
    let sent = await model.send()
    check(sent, "share sent to a new research chat (\(model.sendError ?? ""))")
    model.disconnect()
    let landed = await waitFor("shared message in the app", timeout: 15) {
        gateway.sessions.values.contains { !before.contains($0.key) && $0.agentId == "research" && ($0.preview ?? "").contains(marker) }
    }
    check(landed, "the app sees the new chat with the shared message")
    guard let key = gateway.sessions.values.first(where: { !before.contains($0.key) && $0.agentId == "research" })?.key else { return }
    let chat = gateway.chat(for: key)
    await chat.load(force: true)
    let user = chat.items.first { $0.role == .user }
    check(user?.plainText.contains("https://example.com/paper.pdf") == true, "link included in the message")
    check(user?.blocks.contains { if case .image = $0 { return true } else { return false } } == true, "image attachment delivered")
}
