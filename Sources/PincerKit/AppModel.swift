import Foundation
import Observation

/// Top-level state: saved Gateways ("servers" in the rail) and which one is selected.
@MainActor
@Observable
public final class AppModel {
    public private(set) var gateways: [GatewayStore] = []
    public var selectedGatewayId: UUID? {
        didSet {
            UserDefaults.standard.set(self.selectedGatewayId?.uuidString, forKey: "pincer.selectedGateway")
            self.updateVisible()
        }
    }
    public let notifier = Notifier()
    public var appIsActive = true {
        didSet {
            self.notifier.appIsActive = self.appIsActive
            if self.appIsActive { self.gateways.forEach { $0.reconnectIfNeeded() } }
        }
    }

    public init() {
        self.gateways = GatewayProfileStore.load().map(GatewayStore.init(profile:))
        let saved = UserDefaults.standard.string(forKey: "pincer.selectedGateway").flatMap(UUID.init(uuidString:))
        self.selectedGatewayId = self.gateways.first { $0.id == saved }?.id ?? self.gateways.first?.id
        self.notifier.onOpen = { [weak self] target in self?.open(target) }
        self.notifier.onApprovalAction = { [weak self] gatewayId, approvalId, decision in
            guard let gateway = self?.gateways.first(where: { $0.id == gatewayId }),
                  let approval = gateway.approvals.first(where: { $0.id == approvalId })
            else { return }
            Task { await gateway.resolveApproval(approval, decision: decision) }
        }
    }

    public func start() {
        self.notifier.activate()
        for gateway in self.gateways {
            gateway.notifier = self.notifier
            gateway.start()
        }
        self.updateVisible()
    }

    public var selectedGateway: GatewayStore? {
        self.gateways.first { $0.id == self.selectedGatewayId }
    }

    public var totalUnread: Int { self.gateways.reduce(0) { $0 + $1.totalUnread } }

    /// Call whenever the selected session changes so notifications for it are suppressed.
    public func updateVisible() {
        guard let gateway = self.selectedGateway, let key = gateway.selectedKey else {
            self.notifier.visible = nil
            return
        }
        let target = Notifier.Target(gatewayId: gateway.id, sessionKey: key)
        self.notifier.visible = target
        self.notifier.clear(target: target)
    }

    public func open(_ target: Notifier.Target) {
        guard let gateway = self.gateways.first(where: { $0.id == target.gatewayId }) else { return }
        self.selectedGatewayId = gateway.id
        gateway.selectedKey = target.sessionKey
        self.updateVisible()
    }

    // MARK: Profiles

    @discardableResult
    public func add(_ profile: GatewayProfile, secret: String?) -> GatewayStore {
        profile.secret = secret
        let store = GatewayStore(profile: profile)
        store.notifier = self.notifier
        self.gateways.append(store)
        self.persist()
        self.selectedGatewayId = store.id
        store.start()
        return store
    }

    /// Replaces the connection; the device identity (and thus pairing) is kept.
    public func update(_ profile: GatewayProfile, secret: String?, credentialsChanged: Bool) {
        guard let index = self.gateways.firstIndex(where: { $0.id == profile.id }) else { return }
        self.gateways[index].stop()
        if credentialsChanged {
            profile.secret = secret
            profile.forgetDeviceToken()
        }
        let store = GatewayStore(profile: profile)
        store.notifier = self.notifier
        self.gateways[index] = store
        self.persist()
        store.start()
    }

    public func remove(_ id: UUID) {
        guard let index = self.gateways.firstIndex(where: { $0.id == id }) else { return }
        let store = self.gateways.remove(at: index)
        store.stop()
        store.profile.forgetCredentials()
        TranscriptCache.removeAll(gatewayId: id)
        self.persist()
        if self.selectedGatewayId == id { self.selectedGatewayId = self.gateways.first?.id }
    }

    public func move(_ id: UUID, by offset: Int) {
        guard let index = self.gateways.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), self.gateways.count - 1)
        guard target != index else { return }
        self.gateways.swapAt(index, target)
        self.persist()
    }

    private func persist() {
        GatewayProfileStore.save(self.gateways.map(\.profile))
    }
}
