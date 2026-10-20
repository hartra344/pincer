import Foundation
import Testing
@testable import PincerKit

@Suite("Gateway host vitals")
@MainActor
struct GatewayHostVitalsTests {
    static func payload(pid: Int = 4242, instance: String? = "inst-a", cpu: Double = 0.4, used: Int64 = 8) -> JSONValue {
        var object: [String: JSONValue] = [
            "machineName": "Box", "hostname": "box.local", "platform": "linux", "release": "6.8", "arch": "x64",
            "osLabel": "Ubuntu 24.04", "nodeVersion": "v22.18.0", "pid": .number(Double(pid)), "uptimeMs": 60_000,
            "cpuCount": 8, "cpuModel": "Test CPU", "loadAverage": [1.0, 0.5, 0.25],
            "memoryTotalBytes": 16_000, "memoryFreeBytes": .number(Double(16_000 - used * 1000)),
            "eventLoop": ["degraded": false, "reasons": [], "intervalMs": 1000, "delayP99Ms": 1, "delayMaxMs": 2,
                          "utilization": 0.1, "cpuCoreRatio": 0.2,
                          "cpuBreakdown": ["hostUtilization": .number(cpu), "hostCpuCount": 8]],
            "processMemory": ["rssBytes": 400, "heapUsedBytes": 1, "heapTotalBytes": 2],
            "diskPath": "/", "diskTotalBytes": 1000, "diskAvailableBytes": 400,
            "disks": [["path": "/", "totalBytes": 1000, "availableBytes": 400],
                      ["path": "/mnt/data", "totalBytes": 2000, "availableBytes": 1000]],
        ]
        if let instance { object["processInstanceId"] = .string(instance) }
        return .object(object)
    }

    static let identity: [String: JSONValue] = [
        "machineName": "Box", "hostname": "box.local", "platform": "linux", "release": "6.8", "arch": "x64", "osLabel": "Ubuntu",
    ]

    static func model(_ handler: @escaping @MainActor (String) async throws -> JSONValue) -> GatewayHostVitalsModel {
        GatewayHealthModel { method, _ in try await handler(method) }.host
    }

    @Test func parsesFullPayload() throws {
        let v = try #require(GatewayHostVitals(Self.payload()))
        #expect(v.osLabel == "Ubuntu 24.04" && v.arch == "x64" && v.cpuCount == 8 && v.pid == 4242)
        #expect(v.processInstanceId == "inst-a" && v.cpuModel == "Test CPU" && v.uptimeMs == 60_000)
        #expect(v.loadAverage == [1.0, 0.5, 0.25] && v.hostCpuUtilization == 0.4 && v.processCpuCores == 0.2)
        #expect(v.processRssBytes == 400 && v.memoryTotalBytes == 16_000)
        #expect(v.displayName == "Box" && v.loadPerCore == 0.125)
        #expect(v.memoryUsedBytes == 8000 && v.memoryUsedFraction == 0.5)
    }

    @Test func minimalAndMalformed() throws {
        let minimal = try #require(GatewayHostVitals(.object(Self.identity)))
        #expect(minimal.osLabel == "Ubuntu" && minimal.cpuCount == nil && minimal.disks.isEmpty && minimal.loadAverage == nil)
        #expect(minimal.hostCpuUtilization == nil && minimal.memoryUsedFraction == nil && minimal.primaryDisk == nil)
        let empty = try #require(GatewayHostVitals([:]))
        #expect(empty.osLabel == "" && empty.displayName == "Gateway host")
        #expect(GatewayHostVitals(.null) == nil && GatewayHostVitals("x") == nil && GatewayHostVitals([1, 2]) == nil)
        #expect(GatewayHostVitals(["hostname": "h"])?.displayName == "h")
    }

    @Test func loadAverageAndClamp() throws {
        var short = Self.identity
        short["loadAverage"] = [1.0, 2.0]
        #expect(GatewayHostVitals(.object(short))?.loadAverage == nil)
        short["loadAverage"] = [1.0, -1.0, 2.0]
        #expect(GatewayHostVitals(.object(short))?.loadAverage == nil)
        short["loadAverage"] = [1.0, "x", 2.0]
        #expect(GatewayHostVitals(.object(short))?.loadAverage == nil)
        var clamped = Self.identity
        clamped["eventLoop"] = ["cpuBreakdown": ["hostUtilization": 1.7]]
        #expect(GatewayHostVitals(.object(clamped))?.hostCpuUtilization == 1)
        clamped["eventLoop"] = ["cpuBreakdown": ["hostUtilization": -0.3]]
        #expect(GatewayHostVitals(.object(clamped))?.hostCpuUtilization == nil)
    }

    @Test func diskOrderingAndDedup() throws {
        let v = try #require(GatewayHostVitals(Self.payload()))
        #expect(v.disks.map(\.path) == ["/", "/mnt/data"])
        #expect(v.primaryDisk?.usedFraction == 0.6 && v.disks[1].usedFraction == 0.5)
        var listOnly = Self.identity
        listOnly["disks"] = [["path": "/a", "totalBytes": 100, "availableBytes": 25], ["path": "/b", "totalBytes": 100, "availableBytes": 100]]
        let only = try #require(GatewayHostVitals(.object(listOnly)))
        #expect(only.disks.map(\.path) == ["/a", "/b"] && only.primaryDisk?.usedFraction == 0.75)
        var primaryOnly = Self.identity
        primaryOnly["diskPath"] = "/p"; primaryOnly["diskTotalBytes"] = 10; primaryOnly["diskAvailableBytes"] = 5
        primaryOnly["disks"] = [["path": "/x", "totalBytes": 10, "availableBytes": 10]]
        #expect(GatewayHostVitals(.object(primaryOnly))?.disks.map(\.path) == ["/x"])
        primaryOnly["disks"] = nil
        let legacy = GatewayHostVitals(.object(primaryOnly))
        #expect(legacy?.disks.map(\.path) == ["/p"] && legacy?.primaryDisk?.usedFraction == 0.5)
        primaryOnly["disks"] = []
        #expect(GatewayHostVitals(.object(primaryOnly))?.disks.isEmpty == true, "empty disks array means no disks, not the legacy fallback")
        var mounts = Self.identity
        mounts["diskPath"] = "/Users/x/.openclaw"
        mounts["disks"] = [["path": "/", "totalBytes": 100, "availableBytes": 50], ["path": "/Users", "totalBytes": 100, "availableBytes": 10],
                           ["path": "/Volumes/Archive", "totalBytes": 100, "availableBytes": 10]]
        #expect(GatewayHostVitals(.object(mounts))?.disks.map(\.path) == ["/Users", "/", "/Volumes/Archive"])
    }

    @Test func samplesAndSeries() async throws {
        let model = Self.model { _ in Self.payload() }
        await model.sample()
        await model.sample()
        #expect(model.state == .loaded && model.samples.count == 2 && model.latest != nil)
        #expect(model.samples.allSatisfy { $0.pingMs >= 0 })
        #expect(model.value(.cpu) == 0.4 && model.value(.memory) == 0.5 && model.value(.disk) == 0.6 && model.value(.load) == 1.0)
        #expect(model.value(.ping) == model.latest?.pingMs)
        for metric in GatewayHostVitalsMetric.allCases { #expect(model.series(metric).count == 2) }
        #expect(model.isAvailable)
    }

    @Test func historyCappedAt90() async {
        let model = Self.model { _ in Self.payload() }
        for _ in 0..<95 { await model.sample() }
        #expect(model.samples.count == GatewayHostVitalsModel.historyCapacity && model.samples.count == 90)
        #expect(model.samples.map(\.at) == model.samples.map(\.at).sorted())
    }

    @Test func gapsInSeries() async {
        var step = 0
        let model = Self.model { _ in
            step += 1
            return step == 2 ? .object(Self.identity) : Self.payload()
        }
        for _ in 0..<3 { await model.sample() }
        let cpu = model.series(.cpu)
        #expect(cpu.count == 3 && cpu[0] == 0.4 && cpu[1] == nil && cpu[2] == 0.4)
        #expect(model.series(.ping).allSatisfy { $0 != nil })
    }

    @Test func warnings() async {
        func warning(_ metric: GatewayHostVitalsMetric, cpu: Double = 0.4, used: Int64 = 8) async -> Bool {
            let model = Self.model { _ in Self.payload(cpu: cpu, used: used) }
            await model.sample()
            return model.isWarning(metric)
        }
        let cpuHigh = await warning(.cpu, cpu: 0.9), cpuLow = await warning(.cpu, cpu: 0.89)
        let memHigh = await warning(.memory, used: 15), memLow = await warning(.memory, used: 8)
        #expect(cpuHigh && !cpuLow && memHigh && !memLow)
        let idle = Self.model { _ in .object(Self.identity) }
        await idle.sample()
        for metric in GatewayHostVitalsMetric.allCases where metric != .ping { #expect(!idle.isWarning(metric)) }
        var disk = Self.identity
        disk["diskPath"] = "/"; disk["diskTotalBytes"] = 100; disk["diskAvailableBytes"] = 10
        let full = Self.model { _ in .object(disk) }
        await full.sample()
        #expect(full.isWarning(.disk))
        var load = Self.identity
        load["loadAverage"] = [8.0, 1.0, 1.0]; load["cpuCount"] = 8
        let busy = Self.model { _ in .object(load) }
        await busy.sample()
        #expect(busy.isWarning(.load))
    }

    @Test func slowPingWarns() async {
        let model = Self.model { _ in
            try await Task.sleep(for: .milliseconds(300))
            return Self.payload()
        }
        await model.sample()
        #expect((model.latest?.pingMs ?? 0) > 250 && model.isWarning(.ping))
    }

    @Test func unavailableAndFailures() async {
        let unknown = Self.model { _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: system.info", details: nil) }
        await unknown.sample()
        #expect(unknown.state == .unavailable && unknown.samples.isEmpty && !unknown.isAvailable)
        let forbidden = Self.model { _ in throw GatewayError.rpc(code: "FORBIDDEN", message: "role refused", details: nil) }
        await forbidden.sample()
        #expect(forbidden.state == .unavailable)
        let scope = Self.model { _ in
            throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.read",
                                   details: ["code": "MISSING_SCOPE", "missingScope": "operator.read"])
        }
        await scope.sample()
        if case let .failed(message) = scope.state { #expect(message.contains("operator.read")) } else { Issue.record("expected failed, got \(scope.state)") }
        let other = Self.model { _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "boom", details: nil) }
        await other.sample()
        #expect(other.state == .failed("boom"))
    }

    @Test func missingScopeFlag() async {
        var denied = true
        let model = Self.model { _ in
            if denied { throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.read", details: nil) }
            return Self.payload()
        }
        #expect(!model.missingScope)
        await model.sample()
        #expect(model.missingScope)
        if case .failed = model.state {} else { Issue.record("expected failed, got \(model.state)") }
        model.reset()
        #expect(!model.missingScope)
        await model.sample()
        #expect(model.missingScope)
        denied = false
        await model.sample()
        #expect(!model.missingScope && model.state == .loaded)
        let plain = Self.model { _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "boom", details: nil) }
        await plain.sample()
        #expect(!plain.missingScope)
        let role = Self.model { _ in throw GatewayError.rpc(code: "FORBIDDEN", message: "role refused", details: nil) }
        await role.sample()
        #expect(!role.missingScope && role.state == .unavailable)
    }

    @Test func notAdvertisedIsUnavailable() {
        let health = GatewayHealthModel(methods: { ["health"] }) { _, _ in .null }
        #expect(!health.host.isAvailable)
        let advertised = GatewayHealthModel(methods: { ["health", "system.info"] }) { _, _ in .null }
        #expect(advertised.host.isAvailable)
    }

    @Test func resetClearsAndSupersedesInFlight() async {
        let gate = Gate()
        var first = false
        let model = Self.model { _ in
            if first { first = false; await gate.wait() }
            return Self.payload()
        }
        await model.sample()
        #expect(model.samples.count == 1)
        first = true
        let inFlight = Task { await model.sample() }
        try? await Task.sleep(for: .milliseconds(50))
        model.reset()
        #expect(model.samples.isEmpty && model.state == .idle)
        await gate.open()
        await inFlight.value
        #expect(model.samples.isEmpty && model.state == .idle)
    }

    @Test func resetsWhenGatewayProcessChanges() async {
        var instance: String? = "a", pid = 1
        let model = Self.model { _ in Self.payload(pid: pid, instance: instance) }
        await model.sample(); await model.sample()
        #expect(model.samples.count == 2)
        pid = 2
        await model.sample()
        #expect(model.samples.count == 3, "pid alone is ignored when processInstanceId is present")
        instance = "b"
        await model.sample()
        #expect(model.samples.count == 1 && model.state == .loaded)
        instance = nil
        await model.sample(); await model.sample()
        #expect(model.samples.count == 3)
        pid = 3
        await model.sample()
        #expect(model.samples.count == 1)
    }

    @Test func failureKeepsSamplesButUnavailableClears() async {
        var fail: GatewayError?
        let model = Self.model { _ in
            if let fail { throw fail }
            return Self.payload()
        }
        await model.sample()
        fail = .rpc(code: "UNAVAILABLE", message: "boom", details: nil)
        await model.sample()
        #expect(model.samples.count == 1 && model.state == .failed("boom"))
        fail = .rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)
        await model.sample()
        #expect(model.samples.isEmpty && model.state == .unavailable)
    }

    @Test func pingUsesInjectedClock() async {
        let base = ContinuousClock.now
        let ticks = Ticks(base)
        let model = GatewayHostVitalsModel(clock: { ticks.next() }) { _, _ in Self.payload() }
        await model.sample()
        #expect(model.latest?.pingMs == 40 && model.isWarning(.ping) == false)
    }

    @Test func perfBudget() async {
        let json = Self.payload()
        let clock = ContinuousClock()
        let model = Self.model { _ in json }
        let elapsed = await clock.measure {
            for _ in 0..<90 { await model.sample() }
            for metric in GatewayHostVitalsMetric.allCases { _ = model.series(metric) }
        }
        #expect(model.samples.count == 90 && elapsed < PerfBudget.limit(.milliseconds(5)))
    }
}

private final class Ticks: @unchecked Sendable {
    private var count = 0
    private let base: ContinuousClock.Instant
    init(_ base: ContinuousClock.Instant) { self.base = base }
    func next() -> ContinuousClock.Instant {
        defer { count += 1 }
        return base.advanced(by: .milliseconds(count * 40))
    }
}
