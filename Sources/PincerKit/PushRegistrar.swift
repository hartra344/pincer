import Foundation
import Observation
import PincerPush

/// Registers this device for the Gateway's Web Push so replies and approvals reach iOS while
/// Pincer is suspended or closed.
///
/// The Gateway has no APNs registration for operator clients, but it already sends Web Push
/// (`push.web.subscribe`) for finished replies, exec approvals, questions and failed tasks. Pincer
/// subscribes with an endpoint on the Pincer push relay, which forwards each still-encrypted
/// message to APNs. The Notification Service Extension decrypts it on the device with keys that
/// never leave the Keychain, so neither the relay nor Apple can read it.
@MainActor
@Observable
public final class PushRegistrar {
    public enum Status: Equatable, Sendable {
        case off
        case active
        /// The Gateway doesn't offer Web Push (`push.web.subscribe`).
        case unsupported
        case failed(String)
    }

    public static let shared = PushRegistrar()
    public static let relayKey = "pincer.pushRelay"

    /// APNs device token, hex. Set by the iOS app delegate.
    public private(set) var deviceToken: String?
    public private(set) var status: [UUID: Status] = [:]

    /// `pincer.pushRelay`, or `PINCER_PUSH_RELAY` for development.
    public var relayURL: URL? {
        let raw = ProcessInfo.processInfo.environment["PINCER_PUSH_RELAY"]
            ?? UserDefaults.standard.string(forKey: Self.relayKey) ?? ""
        return Self.validRelay(raw)
    }

    /// APNs environment the token belongs to. The relay also retries the other one.
    public var environment = {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }()

    @ObservationIgnored public var notificationsEnabled: () -> Bool = {
        UserDefaults.standard.object(forKey: "pincer.notifications") as? Bool ?? true
    }
    @ObservationIgnored public var registerWithRelay: (URL, String, String) async throws -> String = PushRegistrar.register
    @ObservationIgnored var onTokenChange: (() -> Void)?

    public init() {}

    public func isActive(_ gatewayId: UUID) -> Bool { self.status[gatewayId] == .active }

    public func setDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard hex != self.deviceToken else { return }
        self.deviceToken = hex
        self.onTokenChange?()
    }

    /// Accepts `https://` relays, and `http://` for loopback during development.
    public static func validRelay(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http" where ["127.0.0.1", "localhost", "::1"].contains(host): return url
        default: return nil
        }
    }

    // MARK: Subscription

    private func storedEndpointKey(_ id: UUID) -> String { "pincer.push.endpoint.\(id.uuidString)" }

    /// Subscribes (or unsubscribes, when push is off) on a connected gateway. Idempotent: the
    /// Gateway upserts by endpoint, so this runs on every connect.
    public func sync(_ gateway: GatewayStore) async {
        guard !gateway.profile.isDemo, gateway.state.isConnected else { return }
        let stored = UserDefaults.standard.string(forKey: self.storedEndpointKey(gateway.id))
        guard self.notificationsEnabled(), let token = self.deviceToken, let relay = self.relayURL else {
            if let stored { await self.unsubscribe(gateway, endpoint: stored) }
            self.status[gateway.id] = .off
            return
        }
        do {
            let id = try await self.relayId(relay: relay, token: token)
            let endpoint = relay.appendingPathComponent("v1/push/\(id)/\(gateway.id.uuidString)").absoluteString
            if let stored, stored != endpoint { await self.unsubscribe(gateway, endpoint: stored) }
            let keys = PushKeyStore.loadOrCreate(for: gateway.id)
            _ = try await gateway.connection.request("push.web.subscribe", [
                "endpoint": .string(endpoint),
                "keys": ["p256dh": .string(keys.p256dh), "auth": .string(keys.auth)],
            ])
            UserDefaults.standard.set(endpoint, forKey: self.storedEndpointKey(gateway.id))
            self.status[gateway.id] = .active
        } catch let error as GatewayError {
            if case let .rpc(code, message, _) = error,
               code == "UNKNOWN_METHOD" || code == "METHOD_NOT_FOUND" || message.contains("unknown method")
            {
                self.status[gateway.id] = .unsupported
            } else {
                self.status[gateway.id] = .failed(error.localizedDescription)
            }
        } catch {
            self.status[gateway.id] = .failed(error.localizedDescription)
        }
    }

    /// Before removing a gateway: drop its subscription and keys.
    public func forget(_ gateway: GatewayStore) async {
        if let stored = UserDefaults.standard.string(forKey: self.storedEndpointKey(gateway.id)) {
            await self.unsubscribe(gateway, endpoint: stored)
        }
        PushKeyStore.delete(for: gateway.id)
        self.status[gateway.id] = nil
    }

    private func unsubscribe(_ gateway: GatewayStore, endpoint: String) async {
        UserDefaults.standard.removeObject(forKey: self.storedEndpointKey(gateway.id))
        _ = try? await gateway.connection.request("push.web.unsubscribe", ["endpoint": .string(endpoint)])
    }

    // MARK: Relay

    /// The relay's opaque id for this token, cached per relay, token and environment.
    private func relayId(relay: URL, token: String) async throws -> String {
        let cacheKey = "\(relay.absoluteString)|\(self.environment)|\(token)"
        if let cached = UserDefaults.standard.dictionary(forKey: "pincer.push.relayId"),
           cached["key"] as? String == cacheKey, let id = cached["id"] as? String
        {
            return id
        }
        let id = try await self.registerWithRelay(relay, token, self.environment)
        UserDefaults.standard.set(["key": cacheKey, "id": id], forKey: "pincer.push.relayId")
        return id
    }

    struct RelayError: LocalizedError {
        let message: String
        var errorDescription: String? { self.message }
    }

    static func register(relay: URL, token: String, environment: String) async throws -> String {
        var request = URLRequest(url: relay.appendingPathComponent("v1/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "environment": environment,
            "topic": Bundle.main.bundleIdentifier ?? "chat.pincer.ios",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let id = object?["id"] as? String else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RelayError(message: "Push relay refused registration (\(object?["error"] as? String ?? "HTTP \(status)")).")
        }
        return id
    }
}
