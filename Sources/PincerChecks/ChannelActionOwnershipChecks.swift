import Foundation
import PincerKit

@MainActor private final class ChannelActionCheckGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                if released || Task.isCancelled { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor func runChannelActionOwnershipChecks() async {
    let gate = ChannelActionCheckGate()
    let key = ChannelAccountKey(channel: "telegram", accountId: "default")
    let model = ChannelsModel(scopes: { [GatewayConnection.adminScope] }) { method, _ in
        if method == "channels.stop" {
            await gate.hold()
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "held local transport failure", details: nil)
        }
        return ["channelOrder": [], "channelAccounts": [:]]
    }
    let old = Task { await model.stop(key) }
    defer { gate.release(); old.cancel() }
    let entered = await waitFor("computed channel action") { gate.entered }
    check(entered, "channel action entered actual request")
    guard entered else { return }
    check(model.isBusy(key), "actual channel action is running")
    model.disconnected()
    gate.release()
    _ = await old.value
    check(model.operation(for: key) == nil && model.notice == nil,
          "old channel failure cannot republish after disconnect")
}

/// Real Demo actions mutate only this owned Demo connection; no synthetic response overlays.
@MainActor func runDemoChannelActionOwnershipChecks() async {
    let connection = GatewayConnection(profile: .demo())
    let ready = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in ready.value = true } }
    })
    await connection.start()
    defer { Task { await connection.stop() } }
    let connected = await waitFor("channel action ownership demo") { ready.value }
    check(connected, "channel action ownership Demo connects")
    guard connected else { return }
    let gate = ChannelActionCheckGate()
    var holdStop = true
    let key = ChannelAccountKey(channel: "discord", accountId: "default")
    let model = ChannelsModel(allowsWritesWithoutAdmin: true) { method, params in
        let response = try await connection.request(method, params)
        if method == "channels.stop", holdStop { await gate.hold() }
        return response
    }
    await model.load()
    check(model.state(of: key) == .connected, "real Demo Discord begins connected")
    let old = Task { await model.stop(key) }
    defer { gate.release(); old.cancel() }
    let entered = await waitFor("real computed Demo stop") { gate.entered }
    check(entered, "real Demo stop response is computed before lifecycle change")
    guard entered else { return }
    model.disconnected()
    gate.release()
    _ = await old.value
    check(model.operation(for: key) == nil && model.notice == nil,
          "real completed Demo stop cannot publish into disconnected lifecycle")
    holdStop = false
    await model.load()
    check(model.state(of: key) == .stopped, "actual backend stop remains applied")
    let started = await model.start(key)
    check(started && model.state(of: key) == .connected && model.notice?.isError == false,
          "current Demo start publishes real recovered status")
}
