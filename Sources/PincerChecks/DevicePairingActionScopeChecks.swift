import Foundation
@testable import PincerKit

@MainActor
func runDevicePairingActionScopeChecks() async {
    let pending = PendingDeviceRequest(["requestId": "scope-request", "deviceId": "other-device", "roles": ["operator"],
                                        "scopes": ["operator.admin"]])!
    var calls: [String] = []
    let model = DeviceManagementModel(scopes: { [DeviceManagementModel.pairingScope] }) { method, _ in
        calls.append(method)
        if method == DeviceManagementModel.approveMethod {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "device pairing approval denied", details: nil)
        }
        return [:]
    }
    check(!model.canManage && model.canApproveDevice && model.canRejectDevice && model.canRemoveDevice,
          "actual pairing-only model exposes only device pairing action capabilities")
    check(!model.canRename && !model.canRenameNodes && !model.canRemoveNodes && model.deviceReadOnlyReason == nil,
          "pairing-only device access retains administrative restrictions without an incorrect read-only notice")
    let approved = await model.approve(pending)
    let rejected = await model.reject(pending)
    check(!approved && rejected && calls == [DeviceManagementModel.approveMethod, DeviceManagementModel.rejectMethod],
          "actual server denial stays local and a later device action still reaches RPC")
    check(!model.canManage && !model.needsAccess, "device action denial does not poison global capability or listing")
}

@MainActor
func runDemoDevicePairingActionScopeChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("device action scope Demo", timeout: 25, { gateway.state.isConnected }) else {
        check(false, "actual device action Demo connects"); return
    }
    // Exercise client admission through the actual connected Demo transport. Demo authority
    // remains unchanged; this does not simulate a device-token authentication mode.
    let model = DeviceManagementModel(methods: { gateway.hello?.methods },
        scopes: { [DeviceManagementModel.pairingScope] }, request: { method, params in
            try await gateway.connection.request(method, params)
        })
    await model.load()
    guard let approvedRequest = model.pending.first(where: { !$0.isRepair }),
          let rejectedRequest = model.pending.first(where: { $0.isRepair }) else {
        check(false, "actual seeded device requests are available"); return
    }
    let approved = await model.approve(approvedRequest)
    check(approved && model.paired.contains { $0.deviceId == approvedRequest.deviceId },
          "actual connected device approval passes pairing-only client admission")
    let rejected = await model.reject(rejectedRequest)
    check(rejected, "actual connected device rejection passes pairing-only client admission")
    guard let device = model.paired.first(where: { $0.deviceId == approvedRequest.deviceId }) else { return }
    let removed = await model.remove(device)
    check(removed, "actual connected device removal passes pairing-only client admission")
    check(!model.canManage && !model.canRenameNodes, "connected client keeps node/admin gate unchanged")
}
