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
func runWebPushChecks() {
    do {
        func b(_ text: String) -> Data { Data(base64URL: text)! }
        // RFC 8291 Appendix A.
        let ua = try! P256.KeyAgreement.PrivateKey(rawRepresentation: b("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"))
        let vectorKeys = WebPushKeys(privateKey: ua, authSecret: b("BTBZMqHH6r4Tts7J_aSIgg"))
        check(vectorKeys.p256dh == "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
              "p256dh is the uncompressed public point")
        let header = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
        let ciphertext = "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ"
        let vector = b(header) + b(ciphertext)
        let plaintext = b("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24")
        check((try? WebPush.decrypt(vector, keys: vectorKeys)) == plaintext, "decrypts the RFC 8291 test vector")
        let asPrivate = try! P256.KeyAgreement.PrivateKey(rawRepresentation: b("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        let reencrypted = try? WebPush.encrypt(plaintext, p256dh: ua.publicKey.x963Representation, auth: vectorKeys.authSecret,
                                               senderPrivate: asPrivate, salt: b("DGv6ra1nlYgDCS1FRnbzlw"))
        check(reencrypted == vector, "encrypts to the RFC 8291 test vector")

        var tampered = vector
        tampered[tampered.count - 1] ^= 1
        check((try? WebPush.decrypt(tampered, keys: vectorKeys)) == nil, "tampered ciphertext is rejected")
        check((try? WebPush.decrypt(vector, keys: .generate())) == nil, "other keys can't decrypt")
        check((try? WebPush.decrypt(vector.prefix(40), keys: vectorKeys)) == nil, "truncated body is rejected")

        let keys = WebPushKeys.generate()
        check(keys.authSecret.count == 16 && Data(base64URL: keys.p256dh)?.count == 65, "generated keys have Web Push sizes")
        let restored = WebPushKeys(stored: keys.stored)
        check(restored?.p256dh == keys.p256dh && restored?.auth == keys.auth, "keys round-trip through storage")
        check(WebPushKeys(stored: "nope") == nil, "malformed stored keys are ignored")
        let text = Data(#"{"title":"OpenClaw agent finished","body":"Done","tag":"t","url":"chat/main"}"#.utf8)
        let sealed = try! WebPush.encrypt(text, p256dh: Data(base64URL: keys.p256dh)!, auth: keys.authSecret)
        check((try? WebPush.decrypt(sealed, keys: restored!)) == text, "encrypt/decrypt round trip")

        let gatewayId = UUID()
        check(PushKeyStore.loadOrCreate(for: gatewayId).stored == PushKeyStore.loadOrCreate(for: gatewayId).stored,
              "push keys persist per gateway")
        check(PushKeyStore.keys(for: UUID()) == nil, "no keys for an unknown gateway")

        print("Push messages")
        func route(_ url: String) -> String { let r = PushMessage.route(url); return "\(r.sessionKey ?? "-")|\(r.approvalId ?? "-")" }
        check(route("chat/main") == "agent:main:main|-", "agent main chat")
        check(route("chat/Main/discord/channel/123") == "agent:main:discord:channel:123|-", "multi-segment session")
        check(route("chat/research/~key/dashboard%3Atrip") == "agent:research:dashboard:trip|-", "~key session, percent-decoded")
        check(route("chat/main#gatewayUrl=wss%3A%2F%2Fgw.example") == "agent:main:main|-", "gatewayUrl fragment ignored")
        check(route("https://gw.example/ui/chat/main?x=1") == "agent:main:main|-", "absolute URL with a base path")
        check(route("approve/abc-123#gatewayUrl=x") == "-|abc-123", "approval path")
        check(route("sessions") == "-|-" && route("chat/") == "-|-" && route("chat/main/~key") == "-|-", "other paths")

        let chatMessage = PushMessage(json: text, gatewayId: gatewayId)
        check(chatMessage?.kind == .chat && chatMessage?.sessionKey == "agent:main:main" && chatMessage?.body == "Done",
              "chat push parsed")
        check(chatMessage?.threadIdentifier == "\(gatewayId.uuidString)|agent:main:main" && chatMessage?.categoryIdentifier == "reply",
              "chat push threads with its chat")
        check(chatMessage?.userInfo == ["gateway": gatewayId.uuidString, "push": "1", "session": "agent:main:main"], "chat push userInfo")
        let pending = PushMessage(json: Data(#"{"title":"OpenClaw approval requested","body":"exec","url":"approve/a1"}"#.utf8), gatewayId: gatewayId)
        check(pending?.kind == .approval(id: "a1", pending: true) && pending?.categoryIdentifier == "approval"
              && pending?.userInfo["approval"] == "a1", "pending approval push has actions")
        if let pending {
            check(pending.userInfo["gateway"] == gatewayId.uuidString
                  && Notifier.interpret(actionIdentifier: "deny", categoryIdentifier: pending.categoryIdentifier, userInfo: pending.userInfo)
                  == .resolve(gatewayId: gatewayId, approvalId: "a1", decision: "deny"), "pending approval push actions resolve on its gateway")
            check(Notifier.categories().first { $0.identifier == pending.categoryIdentifier }?.actions.count == 3,
                  "pending approval push offers all three actions")
        }
        let updated = PushMessage(json: Data(#"{"title":"OpenClaw approval updated","body":"denied","url":"approve/a1"}"#.utf8), gatewayId: gatewayId)
        check(updated?.kind == .approval(id: "a1", pending: false) && updated?.categoryIdentifier == "reply", "resolved approval push has none")
        check(PushMessage(json: Data(#"{"url":"chat/main"}"#.utf8), gatewayId: gatewayId) == nil, "push without text ignored")
        check(PushMessage(json: Data("not json".utf8), gatewayId: gatewayId) == nil, "malformed push ignored")

        let storedKeys = PushKeyStore.loadOrCreate(for: gatewayId)
        let body = try! WebPush.encrypt(text, p256dh: Data(base64URL: storedKeys.p256dh)!, auth: storedKeys.authSecret)
        // The shape the relay sends (push-relay/relay.mjs apnsPayload).
        let apns: [AnyHashable: Any] = ["aps": ["mutable-content": 1], "pincer": ["g": gatewayId.uuidString, "p": body.base64URL]]
        check(PushMessage(apnsPayload: apns) == chatMessage, "relay payload decrypted with the stored keys")
        check(PushMessage(apnsPayload: ["pincer": ["g": UUID().uuidString, "p": body.base64URL]]) == nil, "unknown gateway ignored")
        check(PushMessage(apnsPayload: ["pincer": ["g": gatewayId.uuidString.lowercased(), "p": body.base64URL]]) == chatMessage,
              "lowercase pincer.g → same gateway")
        check(PushMessage(apnsPayload: ["aps": ["alert": "x"]]) == nil, "non-Pincer payload ignored")
        PushKeyStore.delete(for: gatewayId)
        check(PushKeyStore.keys(for: gatewayId) == nil, "push keys deleted")

        print("Push registration")
        check(PushRegistrar.validRelay(" https://push.example.com/relay ")?.absoluteString == "https://push.example.com/relay", "https relay")
        check(PushRegistrar.validRelay("http://127.0.0.1:8787") != nil && PushRegistrar.validRelay("http://localhost:1") != nil,
              "loopback http relay")
        check(PushRegistrar.validRelay("http://push.example.com") == nil && PushRegistrar.validRelay("") == nil
              && PushRegistrar.validRelay("ftp://x") == nil && PushRegistrar.validRelay("https://") == nil, "other relays rejected")

        let notifier = Notifier()
        notifier.pushDelivers = { $0 == gatewayId }
        notifier.appIsActive = false
        check(notifier.deferredToPush(gatewayId), "background: local notification deferred to push")
        check(!notifier.deferredToPush(UUID()), "background without push: local notification posted")
        notifier.appIsActive = true
        check(!notifier.deferredToPush(gatewayId), "foreground: local notification posted")
    }
}

/// Stands in for the push relay: captures what the Gateway POSTs to the subscription endpoint.
final class PushSink: @unchecked Sendable {
    struct Delivery { let path: String; let headers: [String: String]; let body: Data }
    private let listener: NWListener
    private let lock = NSLock()
    private var captured: [Delivery] = []
    var deliveries: [Delivery] { self.lock.withLock { self.captured } }
    var port: UInt16 { self.listener.port?.rawValue ?? 0 }

    init?() {
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.read(connection, buffer: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success else { return nil }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    self.lock.withLock { self.captured.append(Delivery(path: path, headers: headers, body: Data(body.prefix(length)))) }
                    let reply = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if done { connection.cancel() } else { self.read(connection, buffer: buffer) }
        }
    }

    func stop() { self.listener.cancel() }
}

@MainActor
func checkPushLive(_ gateway: GatewayStore) async {
    print("Push (live)")
    guard let sink = PushSink() else { return check(false, "push sink listening") }
    defer { sink.stop() }
    let registrar = PushRegistrar.shared
    let relayKey = PushRegistrar.relayKey
    UserDefaults.standard.set("http://127.0.0.1:\(sink.port)", forKey: relayKey)
    defer { UserDefaults.standard.removeObject(forKey: relayKey) }
    // The relay id is cached in the defaults, which outlive the run; a cache left by an earlier
    // run whose sink got the same port would skip the registration counted below.
    let relayIdKey = "pincer.push.relayId"
    UserDefaults.standard.removeObject(forKey: relayIdKey)
    defer { UserDefaults.standard.removeObject(forKey: relayIdKey) }
    var registrations = 0
    registrar.registerWithRelay = { _, token, _ in registrations += 1; return "relay-\(token.prefix(6))" }
    var enabled = true
    registrar.notificationsEnabled = { enabled }

    await registrar.sync(gateway)
    check(registrar.status[gateway.id] == .off, "no push without an APNs token")
    registrar.setDeviceToken(Data([0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67]))
    await registrar.sync(gateway)
    check(registrar.isActive(gateway.id) && registrations == 1, "subscribed through push.web.subscribe")
    await registrar.sync(gateway)
    check(registrar.isActive(gateway.id) && registrations == 1, "relay id cached across reconnects")

    let chat = gateway.chat(for: "agent:main:main")
    await chat.send("hello from push")
    let delivered = await waitFor("push delivery", timeout: 20) { !sink.deliveries.isEmpty }
    check(delivered, "Gateway POSTed the finished reply to the relay endpoint")
    if let delivery = sink.deliveries.first {
        check(delivery.path == "/v1/push/relay-abcdef/\(gateway.id.uuidString)", "endpoint names the relay id and gateway")
        check(delivery.headers["content-encoding"] == "aes128gcm" && delivery.headers["ttl"] != nil, "Web Push headers")
        let payload: [AnyHashable: Any] = ["pincer": ["g": gateway.id.uuidString, "p": delivery.body.base64URL]]
        let message = PushMessage(apnsPayload: payload)
        check(message?.kind == .chat && message?.sessionKey == "agent:main:main", "decrypted on device: opens the chat")
        check(message?.title == "OpenClaw agent finished", "generic title from the Gateway")
        if let key = message?.sessionKey { check(gateway.resolveSessionKey(key) == "agent:main:main", "push route resolves to a row") }
    }

    let before = sink.deliveries.count
    await chat.send("please approve this")
    let approvalSeen = await waitFor("approval push", timeout: 20) {
        sink.deliveries.dropFirst(before).contains { PushMessage(apnsPayload: ["pincer": ["g": gateway.id.uuidString, "p": $0.body.base64URL]])?.categoryIdentifier == "approval" }
    }
    check(approvalSeen, "approval push carries approve/deny actions")
    let approvalMessage = sink.deliveries.dropFirst(before).lazy
        .compactMap { PushMessage(apnsPayload: ["pincer": ["g": gateway.id.uuidString.lowercased(), "p": $0.body.base64URL]]) }
        .first { $0.categoryIdentifier == "approval" }
    if let approvalMessage, case let .approval(id, _) = approvalMessage.kind {
        let action = Notifier.interpret(actionIdentifier: "deny", categoryIdentifier: approvalMessage.categoryIdentifier,
                                        userInfo: approvalMessage.userInfo)
        check(action == .resolve(gatewayId: gateway.id, approvalId: id, decision: "deny"), "Deny on the decrypted push targets its gateway")
        if case let .resolve(gatewayId, approvalId, decision) = action, gatewayId == gateway.id {
            let outcome = await gateway.resolveApproval(id: approvalId, decision: decision)
            check(outcome == .resolved && gateway.approvals.isEmpty, "approval resolved by id from a push action (\(outcome))")
        }
    } else {
        check(false, "approval push decrypted")
    }
    _ = await waitFor("approval run to finish", timeout: 20) { !chat.isRunning }
    // The run's "agent finished" and "approval updated" pushes are sent after its final event, so
    // they can land after isRunning clears; let them all arrive before unsubscribing.
    await waitForQuiet("pushes from the approval run", timeout: 10) { sink.deliveries.count }

    enabled = false
    await registrar.sync(gateway)
    check(registrar.status[gateway.id] == .off, "notifications off: unsubscribed")
    let after = sink.deliveries.count
    await chat.send("no push now")
    _ = await waitFor("reply", timeout: 20) { !chat.isRunning }
    try? await Task.sleep(for: .milliseconds(500))
    let lateTitles = sink.deliveries.dropFirst(after).compactMap {
        PushMessage(apnsPayload: ["pincer": ["g": gateway.id.uuidString, "p": $0.body.base64URL]])?.title
    }
    check(lateTitles.isEmpty, "no pushes after unsubscribing (\(lateTitles))")
    enabled = true
    await registrar.sync(gateway)
    await registrar.forget(gateway)
    check(registrar.status[gateway.id] == nil && PushKeyStore.keys(for: gateway.id) == nil, "forget drops subscription and keys")
}
