import Foundation
import Testing
@testable import PincerKit

/// Answers `health.summary` like the iOS HealthKit reader would, and records what it was asked.
private final class FakeHealthHandler: DeviceNodeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _invokes: [DeviceNodeInvoke] = []
    private var _permissionCaps: [Set<DeviceCapability>] = []
    var invokes: [DeviceNodeInvoke] { self.lock.withLock { self._invokes } }
    var permissionCaps: [Set<DeviceCapability>] { self.lock.withLock { self._permissionCaps } }

    func permissions(for caps: Set<DeviceCapability>) async -> [String: Bool] {
        self.lock.withLock { self._permissionCaps.append(caps) }
        return Dictionary(uniqueKeysWithValues: caps.map { ($0.rawValue, true) })
    }

    func requestAccess(for cap: DeviceCapability) async -> Bool { true }

    func handle(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        self.lock.withLock { self._invokes.append(invoke) }
        if case let .failure(failure) = HealthSummary.params(invoke.paramsJSON) { return failure.result }
        return HealthSummary.result(HealthSummaryTests.sample)
    }
}

@Suite("Health summary")
struct HealthSummaryTests {
    static let sample = HealthSummary.Payload(
        period: .today, startISO: "2026-10-27T04:00:00Z", endISO: "2026-10-27T19:30:00Z",
        timeZoneIdentifier: "America/New_York", stepCount: 8432, sleepDurationMinutes: 412,
        restingHeartRateBpm: 58.4, workoutCount: 1, workoutDurationMinutes: 42)

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Double) -> Date { Date(timeIntervalSince1970: 1_793_059_200 + hour * 3600) } // 2026-10-27T00:00Z

    @Test func paramsAcceptOnlyToday() {
        #expect(HealthSummary.params(#"{"period":"today"}"#) == .success(.init(period: .today)))
        for bad in [nil, "", "{}", #"{"period":"week"}"#, #"{"period":"yesterday"}"#, "not json"] as [String?] {
            #expect(HealthSummary.params(bad) == .failure(DeviceNodeFailure(
                code: "INVALID_REQUEST", message: "INVALID_REQUEST: period must be today")), "\(String(describing: bad))")
        }
        #expect(HealthSummary.Period.allCases.map(\.rawValue) == ["today"])
        let encoded = try? JSONEncoder().encode(HealthSummary.Params(period: .today))
        #expect(encoded.map { String(decoding: $0, as: UTF8.self) } == #"{"period":"today"}"#)
    }

    @Test func rangeIsLocalMidnightToNow() {
        let now = self.at(15.5)
        #expect(HealthSummary.range(now: now, calendar: Self.utc) == DateInterval(start: self.at(0), end: now))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 15:30Z is 00:30 the next day in Tokyo.
        #expect(HealthSummary.range(now: now, calendar: tokyo).start == self.at(15))
    }

    @Test func sleepMergesOverlapsAndClipsToToday() {
        let today = DateInterval(start: self.at(0), end: self.at(12))
        // Last night from 22:00 to 06:30, a second source overlapping 05:00–07:00, a nap 13:00 (after now).
        let intervals = [
            DateInterval(start: self.at(-2), end: self.at(6.5)),
            DateInterval(start: self.at(5), end: self.at(7)),
            DateInterval(start: self.at(13), end: self.at(14)),
        ]
        #expect(abs((HealthSummary.mergedDuration(intervals, clippedTo: today) ?? 0) - 7 * 3600) < 0.001)
        #expect(HealthSummary.mergedDuration([], clippedTo: today) == nil)
        #expect(HealthSummary.mergedDuration([DateInterval(start: self.at(-5), end: self.at(-1))], clippedTo: today) == nil)
        // Disjoint intervals add up.
        let disjoint = [DateInterval(start: self.at(1), end: self.at(2)), DateInterval(start: self.at(3), end: self.at(3.5))]
        #expect(abs((HealthSummary.mergedDuration(disjoint, clippedTo: today) ?? 0) - 1.5 * 3600) < 0.001)
    }

    @Test func payloadRoundsAndOmitsMissingMetrics() throws {
        let range = DateInterval(start: self.at(0), end: self.at(19.5))
        let raw = HealthSummary.Raw(
            steps: 8431.6, asleep: [DateInterval(start: self.at(-1), end: self.at(5.87))],
            restingHeartRate: 58.437, workoutDurations: [1800, 720.4])
        let payload = HealthSummary.payload(raw, period: .today, range: range, timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(payload == HealthSummary.Payload(
            period: .today, startISO: "2026-10-27T00:00:00Z", endISO: "2026-10-27T19:30:00Z",
            timeZoneIdentifier: "America/New_York", stepCount: 8432, sleepDurationMinutes: 352,
            restingHeartRateBpm: 58.4, workoutCount: 2, workoutDurationMinutes: 42))

        let empty = HealthSummary.payload(HealthSummary.Raw(workoutDurations: []), period: .today, range: range, timeZone: .gmt)
        guard case let .ok(json) = HealthSummary.result(empty) else { Issue.record("encodes"); return }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["period", "startISO", "endISO", "timeZoneIdentifier"], "missing metrics are omitted, not null")
        #expect(object["period"] as? String == "today")
    }

    @Test func resultMatchesUpstreamFieldNames() throws {
        guard case let .ok(json) = HealthSummary.result(Self.sample) else { Issue.record("encodes"); return }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == [
            "period", "startISO", "endISO", "timeZoneIdentifier", "stepCount", "sleepDurationMinutes",
            "restingHeartRateBpm", "workoutCount", "workoutDurationMinutes",
        ])
        #expect(try JSONDecoder().decode(HealthSummary.Payload.self, from: Data(json.utf8)) == Self.sample)
    }

    /// HealthKit belongs to the iOS app only: a Mac build must not carry the entitlement (App Review 2.4.5(i)).
    @Test func healthKitEntitlementIsIOSOnly() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ios = try String(contentsOf: root.appending(path: "Apps/iOS/Pincer.entitlements"), encoding: .utf8)
        #expect(ios.contains("<key>com.apple.developer.healthkit</key>"))
        let macEntitlements = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Apps/macOS").path())
            .filter { $0.hasSuffix(".entitlements") }
        #expect(!macEntitlements.isEmpty)
        for file in macEntitlements {
            let text = try String(contentsOf: root.appending(path: "Apps/macOS/\(file)"), encoding: .utf8)
            #expect(!text.contains("healthkit"), "\(file)")
        }
        let project = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
        #expect(project.components(separatedBy: "NSHealthShareUsageDescription").count == 2, "one usage string, iOS only")
        #expect(!project.contains("NSHealthUpdateUsageDescription"), "read-only: no write usage string")
    }
}

@MainActor
@Suite("Health summary device node (demo)")
struct HealthSummaryDemoTests {
    @Test func demoRoundTripDeclaresHealthAndReportsNoHealthPermission() async throws {
        let scratch = ScratchDefaults()
        let store = GatewayStore(profile: .demo(), defaults: scratch.defaults)
        store.cacheRoot = nil
        let handler = FakeHealthHandler()
        store.deviceNode.handler = handler
        store.deviceNode.supports = { _ in true }
        defer { store.stop(); scratch.remove() }
        store.start()
        #expect(await eventually(timeout: .seconds(10)) { store.state.isConnected })
        await store.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .health]))
        #expect(await eventually(timeout: .seconds(10)) { store.deviceNode.status == .active })
        let demo = try #require(store.connection.demo)
        let node = await demo.demoNodes.first { $0["nodeId"]?.text == DemoGateway.deviceId }
        #expect(DeviceRecords.strings(node?["commands"]) == ["health.summary", "location.get"])
        #expect(DeviceRecords.strings(node?["caps"]) == ["location", "health"])
        #expect(handler.permissionCaps.last == [.location], "no health permission is reported")

        let ok = await store.demoInvokeNode(command: "health.summary", paramsJSON: #"{"period":"today"}"#)
        #expect(ok?["ok"]?.bool == true)
        #expect(ok?["payload"]?["stepCount"]?.int == 8432 && ok?["payload"]?["restingHeartRateBpm"]?.double == 58.4)
        #expect(handler.invokes.last?.paramsJSON == #"{"period":"today"}"#)

        let bad = await store.demoInvokeNode(command: "health.summary", paramsJSON: #"{"period":"week"}"#)
        #expect(bad?["ok"]?.bool == false && bad?["error"]?["message"]?.string == "INVALID_REQUEST: period must be today")
    }
}
