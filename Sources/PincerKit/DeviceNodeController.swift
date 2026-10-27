import Foundation
import Observation

/// Opt-in device mode for one Gateway: a second WebSocket in the `node` role that declares only the
/// capabilities the user checked, and answers the Gateway's `node.invoke.request`s while Pincer is
/// connected. It never runs commands; see `DeviceModePolicy`.
@MainActor @Observable
public final class DeviceNodeController {
    public enum Status: Equatable, Sendable {
        case off, connecting
        /// iOS: the node socket is closed while Pincer is in the background.
        case paused
        case awaitingPairing(requestId: String?)
        /// Connected, but the Gateway hasn't approved the declared commands yet.
        case awaitingApproval(requestId: String?)
        case active
        case failed(String)
    }

    /// Installed once by PincerUI at launch with the real device APIs.
    public static var platformHandler: (any DeviceNodeHandler)?

    public private(set) var settings: DeviceModeSettings
    public private(set) var status: Status = .off
    /// Set when the Gateway refused `node.pair.remove` after device mode was turned off.
    public private(set) var removalHint: String?
    public private(set) var lastInvoke: (command: String, ok: Bool, at: Date)?
    /// Tests and checks inject a fake; otherwise `platformHandler` answers.
    @ObservationIgnored public var handler: (any DeviceNodeHandler)?
    /// What this device can answer. Checks on a Mac widen it to exercise iPhone-only capabilities.
    @ObservationIgnored package var supports: @Sendable (DeviceCapability) -> Bool = { $0.isSupported }

    @ObservationIgnored private let profile: GatewayProfile
    @ObservationIgnored private let identity: DeviceIdentity
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let operatorConnection: GatewayConnection
    @ObservationIgnored private var nodeConnection: GatewayConnection?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var foreground = true
    /// iOS only: a Mac keeps answering while Pincer runs. Tests and checks turn it on elsewhere.
    #if os(iOS)
    @ObservationIgnored package var followsAppLifecycle = true
    #else
    @ObservationIgnored package var followsAppLifecycle = false
    #endif
    @ObservationIgnored private var operatorScopes: Set<String> = []
    @ObservationIgnored private var lastPresenceRefresh = Date.distantPast
    @ObservationIgnored private var invokes = InvokeTracker()
    @ObservationIgnored private var approvalTask: Task<Void, Never>?
    @ObservationIgnored private var surfaceTask: Task<Void, Never>?

    init(profile: GatewayProfile, identity: DeviceIdentity, operatorConnection: GatewayConnection,
         defaults: UserDefaults, handler: (any DeviceNodeHandler)? = nil)
    {
        self.profile = profile
        self.identity = identity
        self.defaults = defaults
        self.operatorConnection = operatorConnection
        self.handler = handler
        self.settings = DeviceModeSettings.load(gatewayId: profile.id, defaults: defaults)
    }

    /// The node id the Gateway knows this device by.
    private var ownNodeId: String { self.profile.isDemo ? DemoGateway.deviceId : self.identity.deviceId }

    private var declared: [String] { self.settings.declaredCommands(supported: self.supports) }

    // MARK: Lifecycle

    /// Persists `new` and starts, restarts or stops the node connection to match.
    public func update(_ new: DeviceModeSettings) async {
        let old = self.settings
        let new = new.sanitized(self.supports)
        self.settings = new
        new.save(gatewayId: self.profile.id, defaults: self.defaults)
        if !new.enabled {
            let wasOn = old.enabled || self.nodeConnection != nil
            await self.teardownNode()
            self.status = .off
            if wasOn { await self.removeNodePairing() }
            return
        }
        self.removalHint = nil
        guard self.running, self.foreground else {
            if self.running, self.status == .off { self.status = .paused }
            return
        }
        if new != old || self.nodeConnection == nil { await self.restartNode() }
    }

    func start() {
        guard !self.running else { return }
        self.running = true
        guard self.settings.enabled else { return }
        guard self.foreground else {
            self.status = .paused
            return
        }
        self.surfaceTask = Task { await self.restartNode() }
    }

    /// iOS closes the node socket once its background time runs out (nothing can answer then) and
    /// reopens it on return. Backgrounding alone keeps it open (#1074).
    func setForeground(_ active: Bool) {
        guard self.followsAppLifecycle, active != self.foreground else { return }
        self.foreground = active
        guard self.running, self.settings.enabled else { return }
        if active {
            self.surfaceTask = Task { await self.restartNode() }
        } else {
            self.surfaceTask?.cancel()
            self.approvalTask?.cancel()
            self.generation += 1
            let connection = self.nodeConnection
            self.nodeConnection = nil
            self.status = .paused
            if let connection { Task { await connection.stop() } }
        }
    }

    func stop() {
        self.running = false
        self.surfaceTask?.cancel()
        self.approvalTask?.cancel()
        self.generation += 1
        let connection = self.nodeConnection
        self.nodeConnection = nil
        self.status = .off
        if let connection { Task { await connection.stop() } }
    }

    /// App returned to the foreground: the node socket may be dead too.
    func reconnectNow() {
        guard let connection = self.nodeConnection else { return }
        Task { await connection.reconnectNow() }
    }

    private func teardownNode() async {
        self.surfaceTask?.cancel()
        self.approvalTask?.cancel()
        self.generation += 1
        let connection = self.nodeConnection
        self.nodeConnection = nil
        await connection?.stop()
    }

    private func restartNode() async {
        self.approvalTask?.cancel()
        self.generation += 1
        let generation = self.generation
        let previous = self.nodeConnection
        self.nodeConnection = nil
        await previous?.stop()
        guard generation == self.generation, self.running else { return }
        let commands = self.declared
        guard !commands.isEmpty else {
            self.status = .off
            return
        }
        let caps = self.settings.capabilities.filter(self.supports)
        self.invokes = InvokeTracker()
        let invokes = self.invokes
        let handler = self.handler ?? Self.platformHandler
        let permissions = await handler?.permissions(for: caps.filter(\.reportsPermission)) ?? [:]
        guard generation == self.generation, self.running else { return }
        let surface = GatewayConnection.Surface.node(
            caps: DeviceCapability.allCases.filter { caps.contains($0) }.map(\.rawValue),
            commands: commands,
            permissions: permissions)
        let connection = GatewayConnection(
            profile: self.profile, identity: self.identity, surface: surface, demo: self.operatorConnection.demo)
        self.nodeConnection = connection
        self.status = .connecting
        let declared = Set(commands)
        let record: @Sendable (String, Bool) -> Void = { [weak self] command, ok in
            Task { @MainActor in self?.lastInvoke = (command, ok, Date()) }
        }
        await connection.setHandlers(
            onEvent: { [weak connection] event in
                if event.name == "node.invoke.cancel" {
                    if let id = event.payload["invokeId"]?.text { invokes.cancel(id) }
                    return
                }
                guard event.name == "node.invoke.request", let connection,
                      let invoke = Self.invoke(from: event.payload) else { return }
                invokes.start(invoke.id) {
                    await Self.answer(invoke, declared: declared, handler: handler, connection: connection, record: record)
                }
            },
            onState: { [weak self] state, _ in
                Task { @MainActor [weak self] in self?.nodeState(state, generation: generation) }
            })
        await connection.start()
    }

    private func nodeState(_ state: ConnectionState, generation: Int) {
        guard generation == self.generation, self.nodeConnection != nil else { return }
        switch state {
        case .idle: break
        case .connecting, .reconnecting:
            self.approvalTask?.cancel()
            if case .awaitingPairing = self.status, case .connecting = state { break }
            self.status = .connecting
        case let .awaitingPairing(requestId, _):
            self.status = .awaitingPairing(requestId: requestId)
        case .connected:
            self.refreshApproval()
        case let .failed(message):
            self.approvalTask?.cancel()
            self.status = .failed(message)
        }
    }

    // MARK: Invoke

    /// Runs one `node.invoke.request` off the main actor and replies with `node.invoke.result`.
    /// A cancelled invoke (`node.invoke.cancel`) sends no reply.
    nonisolated static func answer(
        _ invoke: DeviceNodeInvoke, declared: Set<String>, handler: (any DeviceNodeHandler)?,
        connection: GatewayConnection, record: @Sendable (String, Bool) -> Void) async
    {
        let result = await Self.result(for: invoke, declared: declared, handler: handler)
        guard !Task.isCancelled else { return }
        if case .ok = result { record(invoke.command, true) } else { record(invoke.command, false) }
        _ = try? await connection.request("node.invoke.result", Self.resultParams(invoke: invoke, result: result), timeout: 15)
    }

    nonisolated static func invoke(from payload: JSONValue) -> DeviceNodeInvoke? {
        guard let id = payload["id"]?.text, let nodeId = payload["nodeId"]?.text, let command = payload["command"]?.text
        else { return nil }
        return DeviceNodeInvoke(
            id: id, nodeId: nodeId, command: command, paramsJSON: payload["paramsJSON"]?.string,
            timeoutMs: payload["timeoutMs"]?.int)
    }

    /// Undeclared commands never reach the handler.
    nonisolated static func result(
        for invoke: DeviceNodeInvoke, declared: Set<String>, handler: (any DeviceNodeHandler)?) async -> DeviceNodeResult
    {
        guard declared.contains(invoke.command), !DeviceModePolicy.isForbidden(invoke.command) else {
            return .failure(code: "INVALID_REQUEST", message: "INVALID_REQUEST: unknown command")
        }
        guard let handler else {
            return .failure(code: "UNAVAILABLE", message: "UNAVAILABLE: device access isn't available")
        }
        return await handler.handle(invoke)
    }

    /// `node.invoke.result` params: `{id, nodeId, ok, payloadJSON?, error?: {code, message}}`.
    nonisolated static func resultParams(invoke: DeviceNodeInvoke, result: DeviceNodeResult) -> JSONValue {
        var params: [String: JSONValue] = ["id": .string(invoke.id), "nodeId": .string(invoke.nodeId)]
        switch result {
        case let .ok(payloadJSON):
            params["ok"] = true
            params["payloadJSON"] = .string(payloadJSON)
        case let .failure(code, message):
            params["ok"] = false
            params["error"] = ["code": .string(code), "message": .string(message)]
        }
        return .object(params)
    }

    // MARK: Approval

    /// Operator events. `node.pair.*` only reach operator.pairing connections, so they are a bonus;
    /// `node.presence` (operator.read) is the usual trigger.
    func handleOperatorEvent(_ event: GatewayEvent) {
        guard self.nodeConnection != nil else { return }
        switch event.name {
        case "node.pair.requested", "node.pair.resolved":
            guard event.payload["nodeId"]?.text == self.ownNodeId else { return }
            self.refreshApproval()
        case "node.presence":
            guard self.status == .active || self.status.isAwaitingApproval,
                  Date().timeIntervalSince(self.lastPresenceRefresh) > 2 else { return }
            self.refreshApproval()
        default: break
        }
    }

    /// The operator connection came (back) up.
    func operatorConnected(scopes: [String]) {
        self.operatorScopes = Set(scopes)
        guard self.nodeConnection != nil, self.status.isAwaitingApproval else { return }
        self.refreshApproval()
    }

    enum Approval: Equatable { case approved, pending(requestId: String?), unavailable }

    private func refreshApproval() {
        self.approvalTask?.cancel()
        self.lastPresenceRefresh = Date()
        let generation = self.generation
        self.approvalTask = Task { [weak self] in
            while let self, !Task.isCancelled, generation == self.generation {
                switch await self.queryApproval() {
                case .approved:
                    self.status = .active
                    return
                case let .pending(requestId):
                    self.status = .awaitingApproval(requestId: requestId)
                case .unavailable:
                    break
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// `node.list` needs only operator.read; the self node carries `pendingRequestId` while parked.
    private func queryApproval() async -> Approval {
        let outcome: Result<JSONValue, Error>
        do {
            outcome = .success(try await self.operatorConnection.request("node.list", [:], timeout: 10))
        } catch {
            outcome = .failure(error)
        }
        return Self.approval(outcome, nodeId: self.ownNodeId, wanted: Set(self.declared))
    }

    /// Reads approval from a `node.list` reply. A failed call means "unknown", never approved:
    /// the poll asks again rather than showing Active while the Gateway still holds commands back.
    nonisolated static func approval(_ outcome: Result<JSONValue, Error>, nodeId: String, wanted: Set<String>) -> Approval {
        guard case let .success(result) = outcome else { return .unavailable }
        guard let node = result["nodes"]?.array?.first(where: { $0["nodeId"]?.text == nodeId }) else {
            return .pending(requestId: nil)
        }
        if let requestId = node["pendingRequestId"]?.text { return .pending(requestId: requestId) }
        let commands = Set(DeviceRecords.strings(node["commands"]))
        return wanted.isSubset(of: commands) ? .approved : .pending(requestId: nil)
    }

    // MARK: Turning off

    /// Removing the node role needs operator.admin (and operator.pairing, which admin implies).
    /// The node token is kept unless the Gateway confirms removal, so re-enabling needs no new pairing.
    private func removeNodePairing() async {
        let hint = L("Remove this device’s node role in Devices on the Gateway host.")
        guard self.operatorScopes.contains(GatewayConnection.adminScope) else {
            self.removalHint = hint
            return
        }
        do {
            _ = try await self.operatorConnection.request("node.pair.remove", ["nodeId": .string(self.ownNodeId)], timeout: 10)
            self.profile.nodeDeviceToken = nil
        } catch GatewayError.rpc(_, let message, _) where message.contains("unknown nodeId") {
            self.profile.nodeDeviceToken = nil
        } catch {
            self.removalHint = hint
        }
    }
}

extension DeviceNodeController.Status {
    var isAwaitingApproval: Bool {
        if case .awaitingApproval = self { return true }
        return false
    }
}

/// Running `node.invoke.request` handlers by invoke id, so `node.invoke.cancel` can stop one.
final class InvokeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Starts the handler and records it under the lock, so its own `finish` (or a cancel) can't
    /// slip in before it is recorded.
    func start(_ id: String, _ body: @escaping @Sendable () async -> Void) {
        self.lock.withLock {
            self.tasks[id] = Task.detached(priority: .userInitiated) { [self] in
                await body()
                self.finish(id)
            }
        }
    }

    func finish(_ id: String) {
        self.lock.withLock { _ = self.tasks.removeValue(forKey: id) }
    }

    func cancel(_ id: String) {
        self.lock.withLock { self.tasks.removeValue(forKey: id) }?.cancel()
    }
}
