import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runLocationTransportChecks() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    guard let snapshot = LocationContextSnapshot.prepare(LocationFix(latitude: 37.7749, longitude: -122.4194,
                                                                     accuracyMeters: 18, timestamp: now), now: now) else {
        return check(false, "location transport fixture prepares")
    }
    let authored = "Find a nearby cafe."
    let params = ChatSendRequest.params(sessionKey: "agent:main:main", agentId: nil, message: authored,
        idempotencyKey: "location-check", attachments: [], locationContext: snapshot)
    check(params["message"]?.string == authored && params["workContext"]?["selection"]?.string == snapshot.context,
          "authored body is separate from precise bounded location reference")
    let entry = OutboxEntry(id: "location-check", sessionKey: "agent:main:main", text: authored, locationContext: snapshot, createdAt: now)
    let decoded = (try? JSONEncoder().encode(entry)).flatMap { try? JSONDecoder().decode(OutboxEntry.self, from: $0) }
    check(decoded?.text == authored && decoded?.locationContext == snapshot,
          "outbox relaunch keeps immutable context and authored text independently")
    for command in ["/help", "!uptime"] {
        let commandParams = ChatSendRequest.params(sessionKey: "agent:main:main", agentId: nil, message: command,
            idempotencyKey: "command", attachments: [], locationContext: snapshot)
        check(commandParams["workContext"] == nil && commandParams["message"]?.string == command, "\(command) never carries location")
    }
    let raw: JSONValue = ["role": "user", "content": [["type": "text", "text": "expanded model input"],
        ["type": "image", "artifactId": "map-image"]], "__openclaw": ["id": "location-check-message",
            "workContext": ["snapshot": ChatWorkContext.location(snapshot), "text": .string(authored)]]]
    let item = ChatItem(raw, fallbackIndex: 0)
    check(item?.plainText == authored && item?.id == "location-check-message" && item?.blocks.count == 2,
          "raw location metadata projects once without losing media or identity")
    let legacy = authored + "\n\nLocation context (approximate, shared by Pincer): 📍 37.78, -122.42 ±2000m; observed 2027-01-15T08:00:00Z"
    check(ChatWorkContext.legacyDisplayText(legacy) == authored
          && ChatWorkContext.legacyDisplayText("```text\n" + legacy) == "```text\n" + legacy,
          "strict historical app footer hides only outside authored code examples")
    let oversizedAccuracy = legacy.replacingOccurrences(of: "±2000m", with: "±51601m")
    check(ChatWorkContext.legacyDisplayText(oversizedAccuracy) == oversizedAccuracy,
          "legacy cleanup rejects uncertainty above the old producer's maximum")
}

@MainActor
func runDemoLocationTransportChecks() async {
    await runLocationTransportRoundTrip(profile: .demo(), label: "demo location")
    #if DEBUG
    var legacy = GatewayProfile.demo()
    legacy.url = DemoGateway.noWorkContextAndReplyToURL
    await runLocationTransportRoundTrip(profile: legacy, label: "legacy demo location", expectsFallback: true)
    #endif
}

@MainActor
func runLiveLocationTransportChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Location transport checks", url: url, authMode: .token)
    profile.secret = token
    await runLocationTransportRoundTrip(profile: profile, label: "live location")
}

@MainActor
private func runLocationTransportRoundTrip(profile: GatewayProfile, label: String, expectsFallback: Bool = false) async {
    #if DEBUG
    let suite = "PincerChecks.locationTransport.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start()
    let connected = await waitFor(label + " bootstraps", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped && !gateway.sessions.isEmpty
    }
    check(connected, label + " bootstraps before creating the isolated chat")
    guard connected, let key = await gateway.createSession(agentId: "main", label: label, select: false) else { return }
    gateway.selectedKey = key
    let chat = gateway.chat(for: key)
    await chat.load()
    let ready = await waitFor(label + " history and subscription") { chat.hasLoaded && chat.isSubscribed }
    check(ready && gateway.selectedKey == key, label + " selected chat is loaded and subscribed before delivery")
    guard ready, gateway.selectedKey == key else { return }
    let authored = "Nearby cafe \(UUID().uuidString.prefix(6))"
    let now = Date()
    guard let snapshot = LocationContextSnapshot.prepare(LocationFix(latitude: 37.7749, longitude: -122.4194,
                                                                     accuracyMeters: 18, timestamp: now), now: now) else { return }
    let entry = OutboxEntry(id: UUID().uuidString.lowercased(), sessionKey: key, text: authored, locationContext: snapshot,
                           replyToId: expectsFallback ? "old-message" : nil,
                           replyPreview: expectsFallback ? ReplyPreview(text: "earlier request", senderLabel: "You") : nil, createdAt: now)
    gateway.injectOutboxEntry(entry)
    let outcome = await chat.deliver(entry)
    guard case .sent = outcome else { return check(false, label + " accepts authored send") }
    check(true, label + " accepts authored send")
    let committed = await waitFor(label + " commits") { chat.items.contains { !$0.isPending && $0.role == .user && $0.plainText.hasSuffix(authored) } }
    check(committed, label + " optimistic and committed rows contain no location paragraph")
    do {
        let history = try await gateway.connection.request("chat.history", ["sessionKey": .string(key), "limit": 20])
        let copies = (history["messages"]?.array ?? []).filter { message in
            ChatItem(message, fallbackIndex: 0)?.plainText.hasSuffix(authored) == true && message["role"]?.string == "user"
        }
        check(copies.count == 1, label + " history contains exactly one authored user turn")
        if expectsFallback {
            check(gateway.locationContextUnsupported && gateway.replyToUnsupported && copies.first?["__openclaw"]?["workContext"] == nil,
                  label + " explicit schema fallbacks compose without visible context footer")
        } else {
            check(copies.first?["__openclaw"]?["workContext"]?["snapshot"]?["selection"]?.string == snapshot.context
                  && copies.first?["__openclaw"]?["workContext"]?["text"] == nil,
                  label + " send-time precision survives projected history metadata")
        }
        await chat.abort()
    } catch { check(false, label + " history request: \(error.localizedDescription)") }
    #else
    print("  · location round-trip requires debug checks; skipped")
    #endif
}
