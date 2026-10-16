import Foundation
@testable import PincerKit

@MainActor
private func hostPayload(pid: Int = 1, instance: String = "a") -> JSONValue {
    ["machineName": "Box", "hostname": "box", "platform": "linux", "release": "6", "arch": "x64", "osLabel": "Ubuntu 24.04",
     "pid": .number(Double(pid)), "processInstanceId": .string(instance), "cpuCount": 8, "loadAverage": [1.0, 0.5, 0.2],
     "memoryTotalBytes": 1000, "memoryFreeBytes": 400,
     "eventLoop": ["cpuCoreRatio": 0.2, "cpuBreakdown": ["hostUtilization": 0.95]],
     "diskPath": "/", "diskTotalBytes": 100, "diskAvailableBytes": 50,
     "disks": [["path": "/", "totalBytes": 100, "availableBytes": 50], ["path": "/b", "totalBytes": 200, "availableBytes": 100]]]
}

@MainActor
func runHostVitalsChecks() async {
    let vitals = GatewayHostVitals(hostPayload())
    check(vitals?.osLabel == "Ubuntu 24.04" && vitals?.cpuCount == 8 && vitals?.disks.map(\.path) == ["/", "/b"]
          && vitals?.memoryUsedFraction == 0.6 && vitals?.hostCpuUtilization == 0.95, "host vitals parse verified upstream fields")
    check(GatewayHostVitals([:])?.displayName == "Gateway host" && GatewayHostVitals(.null) == nil
          && GatewayHostVitals(["loadAverage": [1, 2]])?.loadAverage == nil, "minimal and malformed host vitals are tolerated")

    let health = GatewayHealthModel { _, _ in hostPayload() }
    for _ in 0..<95 { await health.host.sample() }
    check(health.host.state == .loaded && health.host.samples.count == GatewayHostVitalsModel.historyCapacity,
          "host vitals history is capped at 90 samples")
    check(health.host.isWarning(.cpu) && !health.host.isWarning(.disk) && health.host.isWarning(.memory) == false,
          "host vitals warn on 90% host CPU only")

    var instance = "a"
    let restarting = GatewayHealthModel { _, _ in hostPayload(instance: instance) }
    await restarting.host.sample(); await restarting.host.sample()
    instance = "b"
    await restarting.host.sample()
    check(restarting.host.samples.count == 1, "host vitals history resets when the Gateway process changes")

    let unknown = GatewayHealthModel { _, _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: system.info", details: nil) }
    await unknown.host.sample()
    check(unknown.host.state == .unavailable && unknown.host.samples.isEmpty, "unknown system.info marks host vitals unavailable")

    var denied = true
    let scoped = GatewayHealthModel { _, _ in
        if denied { throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.read", details: nil) }
        return hostPayload()
    }
    await scoped.host.sample()
    check(scoped.host.missingScope && scoped.host.samples.isEmpty, "a missing-scope refusal sets host vitals missingScope")
    denied = false
    await scoped.host.sample()
    check(!scoped.host.missingScope && scoped.host.state == .loaded, "a successful host sample clears missingScope")

    let gate = HostGate()
    var held = true
    let slow = GatewayHealthModel { _, _ in
        if held { held = false; await gate.hold() }
        return hostPayload()
    }
    let inFlight = Task { await slow.host.sample() }
    _ = await waitFor("host sample in flight", timeout: 5, { gate.entered })
    slow.host.reset()
    gate.release()
    await inFlight.value
    check(slow.host.samples.isEmpty && slow.host.state == .idle, "reset supersedes an in-flight host sample")
}

@MainActor private final class HostGate {
    var entered = false, released = false
    var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiter = continuation }
        }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor
private func runConnectedHostVitalsChecks(profile: GatewayProfile, label: String, os: String, cpus: Int, minDisks: Int) async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("\(label) host vitals connection", timeout: 25) { gateway.state.isConnected }
    check(connected, "\(label) connects for host vitals")
    guard connected else { return }
    do {
        let raw = try await gateway.connection.request("system.info", [:], timeout: 20)
        check(raw["osLabel"]?.text == os && raw["cpuCount"] == .number(Double(cpus)) && raw["memoryTotalBytes"] != nil,
              "\(label) actual system.info RPC returns identity, cpu and memory")
    } catch { check(false, "\(label) system.info RPC failed: \(error)") }
    let health = GatewayHealthModel { method, params in
        try await gateway.connection.request(method, params, timeout: 20)
    }
    await health.host.sample()
    await health.host.sample()
    let host = health.host
    check(host.state == .loaded && host.samples.count == 2, "\(label) host vitals load two samples (state \(host.state))")
    guard let latest = host.latest else { check(false, "\(label) host vitals have a latest sample"); return }
    let v = latest.vitals
    check(v.osLabel == os && v.cpuCount == cpus, "\(label) host vitals report \(os) with \(cpus) CPUs (got \(v.osLabel), \(String(describing: v.cpuCount)))")
    check([host.value(.cpu), host.value(.memory), host.value(.disk)].allSatisfy { $0.map { (0...1).contains($0) } == true },
          "\(label) cpu, memory and disk fractions are within 0...1")
    check(latest.pingMs >= 0 && host.value(.load) != nil && v.disks.count >= minDisks && !v.displayName.isEmpty,
          "\(label) ping, load and disks are present")
}

@MainActor
func runDemoHostVitalsChecks() async {
    await runConnectedHostVitalsChecks(profile: .demo(), label: "Demo", os: "macOS 15.6", cpus: 10, minDisks: 2)
}

@MainActor
func runLiveHostVitalsChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Host vitals mock", url: url, authMode: .token)
    profile.secret = token
    await runConnectedHostVitalsChecks(profile: profile, label: "Mock", os: "Ubuntu 24.04", cpus: 8, minDisks: 2)
}
