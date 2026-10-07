import Foundation
@testable import PincerKit

/// #925: one Double→Int policy for gateway numbers. Non-finite is absent; finite clamps.
@MainActor func runNumericConversionChecks() {
    check([Double.nan, .infinity, -.infinity].allSatisfy { Int(saturating: $0) == nil },
          "non-finite numbers convert to nil (absent), never 0 or Int.max")
    check(Int(saturating: 1e30) == .max && Int(saturating: -1e30) == .min && Int(saturating: Double(Int.max)) == .max,
          "finite numbers outside Int's range clamp")
    check(Int(saturating: 1.5) == 2 && Int(saturating: 1.9, rounding: .towardZero) == 1,
          "in-range numbers round with the caller's rule")
    check(42.0.integerString() == "42" && 1.5.integerString() == nil && 1.5.integerString(rounding: .towardZero) == "1"
          && 1e30.integerString(rounding: .towardZero) == nil && Double.nan.integerString() == nil,
          "integer text has no .0 and refuses values it can't represent exactly")
    check(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": .number(.infinity)]) == nil,
          "a non-finite restart delay is absent, not 'never'")
    check(UsageFormat.duration(ms: 1e30) == UsageFormat.duration(ms: Double(Int.max) * 1000)
          && UsageFormat.duration(ms: .nan) == "<1m" && UsageFormat.duration(ms: .infinity) == "<1m",
          "session usage duration survives huge and non-finite gateway values")
    check(UsageFormat.percent(.infinity) == "0%" && UsageFormat.percent(1e30) == "100%+",
          "usage percent stays in range")
}

/// #927: the outbox file holds a queued message's location snapshot only while the message is queued.
@MainActor func runOutboxLocationAtRestChecks() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "pincer-outbox-location-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = UUID()
    let now = Date()
    guard let snapshot = LocationContextSnapshot.prepare(
        LocationFix(latitude: 47.606209, longitude: -122.332069, accuracyMeters: 12, timestamp: now), now: now),
        let url = OutboxStore.file(gatewayId: gateway, root: root)
    else { return check(false, "prepare a location snapshot") }
    func onDisk() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    var box = Outbox()
    box.enqueue(OutboxEntry(id: "loc", sessionKey: "agent:main:main", text: "where am I", locationContext: snapshot, createdAt: now))
    box.enqueue(OutboxEntry(id: "plain", sessionKey: "agent:main:main", text: "later", createdAt: now))
    await OutboxStore.save(box, gatewayId: gateway, root: root)
    check(onDisk().contains("47.606209"), "a queued message keeps its exact location across relaunch")
    box.reconcile(committedKeys: ["loc"])
    await OutboxStore.save(box, gatewayId: gateway, root: root)
    check(!onDisk().isEmpty && !onDisk().contains("47.606209"), "the location snapshot leaves disk once its message is sent")
    await OutboxStore.save(Outbox(), gatewayId: gateway, root: root)
    check(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "discarding the outbox removes its file")
    check(OutboxStore.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication)
          && !OutboxStore.writeOptions.contains(.completeFileProtection),
          "outbox files are protected at rest but still writable after the device locks")
}
