import Foundation
import Testing
@testable import PincerKit

/// #152: the actual public actions must admit pairing scope and leave final device/role
/// authorization to the Gateway. The injected request records the unchanged wire contract.
@MainActor
@Suite("Device pairing action scope")
struct DevicePairingActionScopeTests {
    private static let pairing = [DeviceManagementModel.pairingScope]
    private static let methods: Set<String> = [
        DeviceManagementModel.listMethod, DeviceManagementModel.approveMethod,
        DeviceManagementModel.rejectMethod, DeviceManagementModel.removeMethod,
        DeviceManagementModel.renameMethod, DeviceManagementModel.nodeListMethod,
        DeviceManagementModel.nodeRenameMethod, DeviceManagementModel.nodeRemoveMethod,
    ]

    private func spy() -> ScriptedDevices {
        let spy = ScriptedDevices(list: DeviceFixtures.list(
            pending: [DeviceFixtures.pending("r1", deviceId: DeviceFixtures.otherId)],
            paired: [DeviceFixtures.paired(DeviceFixtures.otherId)]))
        spy.results[DeviceManagementModel.approveMethod] = [
            "requestId": "r1", "device": DeviceFixtures.paired(DeviceFixtures.otherId),
        ]
        return spy
    }

    private func model(_ spy: ScriptedDevices, scopes: [String]? = nil,
                       methods: Set<String>? = nil) -> DeviceManagementModel {
        let scopes = scopes ?? Self.pairing
        let methods = methods ?? Self.methods
        return DeviceManagementModel(methods: { methods }, scopes: { scopes }, selfDeviceId: DeviceFixtures.selfId,
                              request: { method, params in try spy.request(method, params) })
    }

    private func act(_ method: String, model: DeviceManagementModel) async throws -> Bool {
        switch method {
        case DeviceManagementModel.approveMethod:
            let request = try #require(model.pending.first)
            return await model.approve(request)
        case DeviceManagementModel.rejectMethod:
            let request = try #require(model.pending.first)
            return await model.reject(request)
        case DeviceManagementModel.removeMethod:
            let device = try #require(model.paired.first)
            return await model.remove(device)
        default:
            Issue.record("Use an existing device pairing method")
            return false
        }
    }

    @Test(arguments: [DeviceManagementModel.approveMethod, DeviceManagementModel.rejectMethod,
                      DeviceManagementModel.removeMethod])
    func pairingOnlyActuallySendsSupportedAction(_ method: String) async throws {
        let spy = self.spy()
        let model = self.model(spy)
        await model.load()
        try #require(model.pending.count == 1 && model.paired.count == 1)
        #expect(model.canView && !model.canManage,
                "Global management authority remains admin-only")
        #expect(!model.canRename && !model.canRenameNodes && !model.canRemoveNodes,
                "Pairing scope must not expand unrelated administrative actions")
        let succeeded = try await self.act(method, model: model)
        #expect(succeeded, "The real pairing-only action must reach its RPC")
        let expected: JSONValue = method == DeviceManagementModel.removeMethod
            ? ["deviceId": .string(DeviceFixtures.otherId)] : ["requestId": "r1"]
        #expect(spy.params(method) == [expected], "Do not add caller-role, token or scope fields to the established request")
        if method == DeviceManagementModel.removeMethod { #expect(model.paired.isEmpty) }
        else { #expect(model.pending.isEmpty) }
    }

    @Test(arguments: [DeviceManagementModel.approveMethod, DeviceManagementModel.rejectMethod,
                      DeviceManagementModel.removeMethod])
    func adminActionsKeepTheirExactWireContract(_ method: String) async throws {
        let spy = self.spy()
        let model = self.model(spy, scopes: [GatewayConnection.adminScope])
        await model.load()
        #expect(model.canManage && model.canRename && model.canRenameNodes && model.canRemoveNodes)
        let succeeded = try await self.act(method, model: model)
        #expect(succeeded)
        let expected: JSONValue = method == DeviceManagementModel.removeMethod
            ? ["deviceId": .string(DeviceFixtures.otherId)] : ["requestId": "r1"]
        #expect(spy.params(method) == [expected])
    }

    @Test func missingPairingScopeCannotSendAnyPairingAction() async throws {
        let spy = self.spy()
        let model = self.model(spy, scopes: GatewayConnection.scopes)
        let request = try #require(PendingDeviceRequest(DeviceFixtures.pending("r1")))
        let device = try #require(PairedDevice(DeviceFixtures.paired(DeviceFixtures.otherId)))
        #expect(!model.canView && !model.canManage)
        let approved = await model.approve(request)
        let rejected = await model.reject(request)
        let removed = await model.remove(device)
        #expect(!approved && !rejected && !removed)
        #expect(spy.calls.isEmpty)
    }

    @Test(arguments: [DeviceManagementModel.approveMethod, DeviceManagementModel.rejectMethod,
                      DeviceManagementModel.removeMethod])
    func explicitlyUnsupportedActionCannotSendEvenWithAdmin(_ method: String) async throws {
        let spy = self.spy()
        let model = self.model(spy, scopes: [GatewayConnection.adminScope],
                               methods: Self.methods.subtracting([method]))
        await model.load()
        try #require(model.pending.count == 1 && model.paired.count == 1)
        #expect(!model.supports(method))
        let succeeded = try await self.act(method, model: model)
        #expect(!succeeded)
        #expect(spy.params(method).isEmpty, "An advertised missing pairing method cannot be sent")
        #expect(model.pending.count == 1 && model.paired.count == 1)
    }

    @Test func pairingScopeCannotSendRenameOrNodeMutations() async throws {
        let spy = self.spy()
        let model = self.model(spy)
        await model.load()
        let device = try #require(model.paired.first)
        let node = try #require(GatewayNode(DeviceFixtures.node("node-other", name: "Other node")))
        let renamed = await model.rename(device, to: "Renamed device")
        let nodeRenamed = await model.renameNode(node, to: "Renamed node")
        let nodeRemoved = await model.removeNode(node)
        #expect(!renamed && !nodeRenamed && !nodeRemoved)
        #expect(spy.params(DeviceManagementModel.renameMethod).isEmpty)
        #expect(spy.params(DeviceManagementModel.nodeRenameMethod).isEmpty)
        #expect(spy.params(DeviceManagementModel.nodeRemoveMethod).isEmpty)
    }

    @Test func pairingOnlyDenialStaysOnRequestAndDoesNotPoisonOtherActions() async throws {
        let spy = self.spy()
        spy.failures[DeviceManagementModel.approveMethod] = DeviceFixtures.rpc(
            "INVALID_REQUEST", "device pairing approval denied")
        let model = self.model(spy)
        await model.load()
        let request = try #require(model.pending.first)
        let device = try #require(model.paired.first)
        let approved = await model.approve(request)
        #expect(!approved)
        #expect(spy.params(DeviceManagementModel.approveMethod) == [["requestId": "r1"]])
        #expect(model.pending == [request], "A Gateway denial preserves the actual request")
        #expect(model.operation(for: request) == .failed("device pairing approval denied"),
                "Keep the actionable Gateway error on this operation")
        #expect(!model.canManage && model.canView && !model.needsAccess)
        let rejected = await model.reject(request)
        let removed = await model.remove(device)
        #expect(rejected && removed, "Denial of approve cannot suppress independent reject/remove RPCs")
        #expect(spy.params(DeviceManagementModel.rejectMethod) == [["requestId": "r1"]])
        #expect(spy.params(DeviceManagementModel.removeMethod) == [["deviceId": .string(DeviceFixtures.otherId)]])
        #expect(model.pending.isEmpty && model.paired.isEmpty)
    }

    @Test func pairingOnlyScopeDenialCanRecoverOnReconnect() async throws {
        let spy = self.spy()
        spy.failures[DeviceManagementModel.approveMethod] = DeviceFixtures.missingScope
        let model = self.model(spy)
        await model.load()
        let request = try #require(model.pending.first)
        let first = await model.approve(request)
        #expect(!first)
        #expect(spy.params(DeviceManagementModel.approveMethod).count == 1)
        #expect(model.pending == [request] && !model.canManage && !model.needsAccess)
        if case let .failed(message) = model.operation(for: request) { #expect(!message.isEmpty) }
        else { Issue.record("A scope denial must remain visible on the failed operation") }
        model.handleReconnect()
        spy.failures.removeValue(forKey: DeviceManagementModel.approveMethod)
        let retried = await model.approve(request)
        #expect(retried && model.pending.isEmpty)
        #expect(spy.params(DeviceManagementModel.approveMethod).count == 2)
    }

    @Test(arguments: [DeviceManagementModel.approveMethod, DeviceManagementModel.rejectMethod,
                      DeviceManagementModel.removeMethod])
    func stalePairingIDsAreResolvedByTheGateway(_ method: String) async throws {
        let spy = self.spy()
        spy.failures[method] = DeviceFixtures.rpc("INVALID_REQUEST",
            method == DeviceManagementModel.removeMethod ? "unknown deviceId" : "unknown requestId")
        let model = self.model(spy)
        await model.load()
        spy.results[DeviceManagementModel.listMethod] = DeviceFixtures.list()
        let resolved = try await self.act(method, model: model)
        #expect(resolved)
        #expect(spy.params(method).count == 1)
        #expect(model.notice?.severity == .warning)
        #expect(model.pending.isEmpty && model.paired.isEmpty)
        #expect(model.canView && !model.canManage)
    }

    @Test(arguments: [DeviceManagementModel.rejectMethod, DeviceManagementModel.removeMethod])
    func gatewayDeniedActionPreservesTargetAndAllowsSameSessionRetry(_ method: String) async throws {
        let spy = self.spy()
        let message = method == DeviceManagementModel.rejectMethod
            ? "device pairing rejection denied" : "device pairing removal denied"
        spy.failures[method] = DeviceFixtures.rpc("INVALID_REQUEST", message)
        let model = self.model(spy)
        await model.load()
        let request = try #require(model.pending.first)
        let device = try #require(model.paired.first)
        let denied = try await self.act(method, model: model)
        #expect(!denied && spy.params(method).count == 1)
        #expect(model.pending == [request] && model.paired == [device])
        let operation = method == DeviceManagementModel.rejectMethod
            ? model.operation(for: request) : model.operation(for: device)
        #expect(operation == .failed(message))
        #expect(model.canApproveDevice && model.canRejectDevice && model.canRemoveDevice)
        #expect(!model.canManage && !model.canRename && !model.canRemoveNodes)
        // The Gateway may permit a subsequent operation without a connection transition.
        spy.failures.removeValue(forKey: method)
        let retried = try await self.act(method, model: model)
        #expect(retried && spy.params(method).count == 2)
        let independent: Bool
        if method == DeviceManagementModel.rejectMethod {
            independent = await model.remove(device)
        } else {
            independent = await model.reject(request)
        }
        #expect(independent, "An opaque Gateway denial must not poison independent pairing operations")
    }

    @Test(arguments: [false, true])
    func gatewayScopeDenialIsAuthoritativeEvenWhenPendingScopesDoNotExplainIt(_ hiddenExistingGrant: Bool) async throws {
        let requestedScopes = hiddenExistingGrant ? ["operator.read"] : ["operator.read", "operator.write"]
        let spy = ScriptedDevices(list: DeviceFixtures.list(
            pending: [DeviceFixtures.pending("r1", deviceId: DeviceFixtures.otherId, scopes: requestedScopes)],
            paired: [DeviceFixtures.paired(DeviceFixtures.otherId, scopes: ["operator.read"])]))
        spy.failures[DeviceManagementModel.approveMethod] = DeviceFixtures.rpc(
            "INVALID_REQUEST", "missing scope: operator.write")
        let model = self.model(spy, scopes: ["operator.read", DeviceManagementModel.pairingScope])
        await model.load()
        let request = try #require(model.pending.first)
        #expect(request.scopes.contains("operator.write") != hiddenExistingGrant)
        #expect(model.canApproveDevice,
                "Pending rows cannot predict the Gateway's historical grants or caller authorization")
        let approved = await model.approve(request)
        #expect(!approved)
        #expect(spy.params(DeviceManagementModel.approveMethod) == [["requestId": "r1"]])
        #expect(model.pending == [request])
        #expect(model.operation(for: request) == .failed("missing scope: operator.write"),
                "Preserve the Gateway's scope error on the actual request")
        #expect(model.canApproveDevice && model.canRejectDevice && model.canRemoveDevice)
        #expect(model.canView && !model.canManage && !model.needsAccess)
        let rejected = await model.reject(request)
        #expect(rejected && spy.params(DeviceManagementModel.rejectMethod) == [["requestId": "r1"]])
    }

    @Test func unsupportedDeviceActionsHaveAccurateRecoveryGuidance() async {
        let model = self.model(self.spy(), scopes: [GatewayConnection.adminScope],
                               methods: [DeviceManagementModel.listMethod])
        #expect(model.canManage)
        #expect(!model.canApproveDevice && !model.canRejectDevice && !model.canRemoveDevice)
        #expect(model.deviceReadOnlyReason == DeviceManagementModel.unsupportedMessage,
                "Administrative scope cannot make an unsupported method available")
    }

    @Test func adminWithPairingScopeCannotBypassLegacyDeniedManagement() async throws {
        let spy = self.spy()
        spy.failures[DeviceManagementModel.approveMethod] = DeviceFixtures.rpc(
            "INVALID_REQUEST", "device pairing approval denied")
        let model = self.model(spy, scopes: [GatewayConnection.adminScope, DeviceManagementModel.pairingScope])
        await model.load()
        let request = try #require(model.pending.first)
        let denied = await model.approve(request)
        #expect(!denied && !model.canManage)
        #expect(!model.canApproveDevice && !model.canRejectDevice && !model.canRemoveDevice)
        #expect(model.deviceReadOnlyReason == DeviceManagementModel.readOnlyMessage)
        let rejected = await model.reject(request)
        #expect(!rejected && spy.params(DeviceManagementModel.rejectMethod).isEmpty)
    }

}
