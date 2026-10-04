import Foundation
import Observation

/// `web.login.start` / `web.login.wait` results (operator.admin; not advertised in `hello.methods`).
public struct WebLoginResult: Hashable, Sendable {
    public let qrDataUrl: String?
    public let sessionKey: String?
    public let connected: Bool?
    public let message: String?

    public init(_ json: JSONValue) {
        self.qrDataUrl = json["qrDataUrl"]?.text
        self.sessionKey = json["sessionKey"]?.text
        self.connected = json["connected"]?.bool
        self.message = json["message"]?.text
    }

    init(qrDataUrl: String?, sessionKey: String?, connected: Bool?, message: String?) {
        self.qrDataUrl = qrDataUrl
        self.sessionKey = sessionKey
        self.connected = connected
        self.message = message
    }

    /// The PNG in `qrDataUrl` (`data:image/png;base64,…`).
    public var qrImageData: Data? {
        guard let url = self.qrDataUrl, let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }
}

/// QR login for one channel account (`web.login.start`, then `web.login.wait`).
public enum ChannelQRLoginState: Hashable, Sendable {
    case idle
    case starting
    /// Scan this; `web.login.wait` is running.
    case showing(qr: Data, message: String?)
    case connected(String?)
    case failed(String)

    public var isRunning: Bool {
        switch self {
        case .starting, .showing: true
        default: false
        }
    }
}

/// Runs QR logins for channel accounts, shared by the setup wizard and Channel Status.
@MainActor
@Observable
public final class ChannelQRLoginController {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// Keyed by `key(channel:accountId:)`.
    public private(set) var logins: [String: ChannelQRLoginState] = [:]
    /// Called once an account links (or turns out to be linked already), e.g. to reload status.
    @ObservationIgnored public var onLinked: (@MainActor (ChannelAccountKey) async -> Void)?

    @ObservationIgnored private let request: Request
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Only active login attempts retain a token; finished accounts keep their visible state.
    @ObservationIgnored private var owners: [String: UUID] = [:]

    public init(request: @escaping Request) {
        self.request = request
    }

    public nonisolated static let startTimeoutMs = 30000
    public nonisolated static let waitTimeoutMs = 120_000
    public nonisolated static let maxRounds = 5

    public nonisolated static func key(channel: String, accountId: String?) -> String { "\(channel)/\(accountId ?? "default")" }

    public func state(channel: String, accountId: String?) -> ChannelQRLoginState {
        self.logins[Self.key(channel: channel, accountId: accountId)] ?? .idle
    }

    #if DEBUG
    /// Read-only access to the actual active attempt for deterministic completion checks.
    package func activeTaskForChecks(channel: String, accountId: String?) -> Task<Void, Never>? {
        self.tasks[Self.key(channel: channel, accountId: accountId)]
    }
    #endif

    /// Any login showing a QR or starting.
    public var hasRunning: Bool { self.logins.values.contains(where: \.isRunning) }

    /// `web.login.start` then `web.login.wait` (refreshing the QR when the provider rotates it)
    /// until connected, failed or cancelled.
    public func start(channel: String, accountId: String?, force: Bool = false) {
        let key = Self.key(channel: channel, accountId: accountId)
        self.tasks[key]?.cancel()
        let owner = UUID()
        self.owners[key] = owner
        self.logins[key] = .starting
        self.tasks[key] = Task { [weak self] in
            await self?.run(key: key, owner: owner, channel: channel, accountId: accountId, force: force)
        }
    }

    public func cancel(channel: String, accountId: String?) {
        let key = Self.key(channel: channel, accountId: accountId)
        self.owners.removeValue(forKey: key)
        self.tasks.removeValue(forKey: key)?.cancel()
        self.logins[key] = nil
    }

    /// Stops every running login; finished ones keep their result.
    public func cancelAll() {
        for task in self.tasks.values { task.cancel() }
        self.tasks = [:]
        self.owners = [:]
        self.logins = self.logins.filter { !$0.value.isRunning }
    }

    /// Forgets every login, e.g. on disconnect.
    public func reset() {
        for task in self.tasks.values { task.cancel() }
        self.tasks = [:]
        self.owners = [:]
        self.logins = [:]
    }

    /// Upstream has no structured flag for a wait that timed out; the WhatsApp and Zalo plugins both
    /// return `connected:false` with a "Still waiting…" message, while other messages are terminal.
    public nonisolated static func isStillWaiting(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("still waiting")
    }

    /// Upstream `web.login.start` without `force` on a linked account answers with just a message:
    /// WhatsApp "WhatsApp is already linked (…). Say “relink” …", Zalo "Zalo is already linked (…)."
    /// Relinking is `start(…, force: true)`.
    public nonisolated static func isAlreadyLinked(_ message: String) -> Bool {
        message.lowercased().contains("is already linked")
    }

    private func linked(_ key: String, owner: UUID, channel: String, accountId: String?, message: String?) async {
        guard self.isCurrent(key, owner: owner) else { return }
        self.logins[key] = .connected(message)
        await self.onLinked?(ChannelAccountKey(channel: channel, accountId: accountId))
    }

    private func isCurrent(_ key: String, owner: UUID) -> Bool {
        !Task.isCancelled && self.owners[key] == owner
    }

    private func run(key: String, owner: UUID, channel: String, accountId: String?, force: Bool) async {
        guard self.isCurrent(key, owner: owner) else { return }
        defer {
            // An older completion, including one returning from onLinked, must not
            // remove a replacement attempt's task or ownership.
            if self.owners[key] == owner {
                self.owners.removeValue(forKey: key)
                self.tasks.removeValue(forKey: key)
            }
        }
        var start: [String: JSONValue] = ["channel": .string(channel), "force": .bool(force),
                                          "timeoutMs": .number(Double(Self.startTimeoutMs))]
        if let accountId { start["accountId"] = .string(accountId) }
        do {
            var result = WebLoginResult(try await self.request("web.login.start", .object(start)))
            guard self.isCurrent(key, owner: owner) else { return }
            var rounds = 0
            while self.isCurrent(key, owner: owner) {
                if result.connected == true {
                    await self.linked(key, owner: owner, channel: channel, accountId: accountId, message: result.message)
                    return
                }
                // Starting on a linked account returns only a message (no `connected` flag): it's linked.
                if result.qrImageData == nil, let message = result.message, Self.isAlreadyLinked(message) {
                    await self.linked(key, owner: owner, channel: channel, accountId: accountId, message: message)
                    return
                }
                guard let qr = result.qrImageData else {
                    self.logins[key] = .failed(result.message ?? "The Gateway didn't send a QR code.")
                    return
                }
                self.logins[key] = .showing(qr: qr, message: result.message)
                rounds += 1
                guard rounds <= Self.maxRounds else {
                    self.logins[key] = .failed("The QR code expired. Try again.")
                    return
                }
                var wait: [String: JSONValue] = ["channel": .string(channel), "timeoutMs": .number(Double(Self.waitTimeoutMs))]
                if let accountId { wait["accountId"] = .string(accountId) }
                if let sessionKey = result.sessionKey { wait["sessionKey"] = .string(sessionKey) }
                if let url = result.qrDataUrl { wait["currentQrDataUrl"] = .string(url) }
                let next = WebLoginResult(try await self.request("web.login.wait", .object(wait)))
                guard self.isCurrent(key, owner: owner) else { return }
                // A wait without a new QR keeps showing the current one.
                result = next.qrDataUrl == nil && next.connected != true
                    ? WebLoginResult(qrDataUrl: result.qrDataUrl, sessionKey: next.sessionKey ?? result.sessionKey,
                                     connected: next.connected, message: next.message)
                    : next
                if next.connected == false, next.qrDataUrl == nil, let message = next.message,
                   !Self.isStillWaiting(message) {
                    self.logins[key] = .failed(message)
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.isCurrent(key, owner: owner) else { return }
            self.logins[key] = .failed(ChannelRules.errorText(error))
        }
    }
}
