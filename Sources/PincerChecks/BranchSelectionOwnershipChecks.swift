#if DEBUG
import Foundation
@testable import PincerKit

private actor BranchDelivery {
    var entered = false, released = false
    var waiter: CheckedContinuation<Void, Never>?
    func hold(_ method: String) async {
        guard method == "sessions.fork" else { return }
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { await self.release() } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
@MainActor private func checkActualBranchSelection(change: Int) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual branch Demo bootstrap", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    let sourceKey = "agent:main:dashboard:garden", otherKey = "agent:main:dashboard:trip"
    guard ready, gateway.hello?.methods.contains("sessions.fork") == true,
          gateway.sessions[sourceKey] != nil, gateway.sessions[otherKey] != nil else {
        check(false, "actual fork method and distinct seeded chats ready"); return
    }
    check(true, "actual fork method and seeded chats ready")
    let chat = gateway.chat(for: sourceKey)
    await chat.load()
    guard let user = chat.items.last(where: { $0.role == .user && $0.isCommittedEntry && $0.transcriptId != nil }),
          !user.plainText.isEmpty, chat.canBranch(from: user.id) else {
        check(false, "actual committed user can branch"); return
    }
    let text = user.plainText
    check(true, "actual committed user has editor text and can branch")
    gateway.selectedKey = sourceKey
    let before = Set(gateway.sessions.keys)
    let delivery = BranchDelivery()
    await gateway.connection.setDemoResponseDelivery { await delivery.hold($0) }
    let action = Task { await chat.branch(from: user.id) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    var entered = await delivery.entered
    while !entered && !Task.isCancelled && ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        entered = await delivery.entered
    }
    check(entered, "actual fork result computed before held delivery")
    guard entered else {
        action.cancel(); await delivery.release(); _ = await action.value
        await gateway.connection.setDemoResponseDelivery(nil); return
    }
    check(gateway.selectedKey == sourceKey, "fork admission leaves source selected")
    if change > 0 { gateway.selectedKey = otherKey }
    if change == 2 { gateway.selectedKey = sourceKey }
    let expected = gateway.selectedKey
    await delivery.release()
    let result = await action.value
    await gateway.connection.setDemoResponseDelivery(nil)
    guard let created = result else { check(false, "actual fork completes successfully"); return }
    check(created != sourceKey && gateway.sessions[created]?.key == created && Set(gateway.sessions.keys).subtracting(before) == [created], "actual fork adds exactly its returned real row")
    check(gateway.chat(for: created).draft.text == text && chat.errorMessage == nil, "actual user fork preserves full editor text")
    check(gateway.selectedKey == (change == 0 ? created : expected), "actual fork completion preserves newer B or ABA selection")
}
@MainActor func runBranchSelectionOwnershipChecks() async {
    for change in [0, 1, 2] { await checkActualBranchSelection(change: change) }
}
@MainActor func runDemoBranchSelectionOwnershipChecks() async {
    for change in [0, 1, 2] { await checkActualBranchSelection(change: change) }
}
#endif
