import Foundation
import CryptoKit
@testable import PincerKit

@MainActor
private final class LocationContextCheckDriver: LocationContextDriver {
    var authorization: LocationAuthorization
    var authorizationRequests = 0
    var requestedGenerations: [Int] = []
    var stops = 0

    init(_ authorization: LocationAuthorization) { self.authorization = authorization }
    func requestAuthorization() { self.authorizationRequests += 1 }
    func requestLocation(generation: Int) { self.requestedGenerations.append(generation) }
    func stop() { self.stops += 1 }
}

@MainActor
func runLocationContextChecks() async {
    let now = Date()
    let snapshot = LocationContextSnapshot.prepare(
        LocationFix(latitude: 47.6062, longitude: -122.3321, accuracyMeters: 12, timestamp: now), now: now)
    check(snapshot?.context.contains("47.60, -122.34") == true
          && snapshot?.context.contains("±2000m") == true
          && snapshot?.context.contains("47.6062") == false,
          "location context is quantized, bounded, and never includes precise coordinates")
    check(snapshot?.isFresh(at: now.addingTimeInterval(300)) == true
          && snapshot?.isFresh(at: now.addingTimeInterval(301)) == false,
          "location context expires after five minutes")
    let conservative = LocationContextSnapshot.prepare(
        LocationFix(latitude: 47.6062, longitude: -122.3321, accuracyMeters: 4_000, timestamp: now), now: now)
    check(conservative?.context.contains("±5600m") == true,
          "reported uncertainty includes the additional quantization margin")
    check(LocationContextSnapshot.prepare(
        LocationFix(latitude: 47.6, longitude: -122.3, accuracyMeters: 20,
                    timestamp: now.addingTimeInterval(1)), now: now) == nil,
          "a future location fix is rejected")

    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = LocationContextModel(defaults: defaults)
    let driver = LocationContextCheckDriver(.notDetermined)
    model.configure(driver: driver)
    model.setEnabled(true)
    check(model.enabled && driver.authorizationRequests == 0,
          "location opt-in waits for an active app before requesting permission")
    model.setActive(true)
    check(driver.authorizationRequests == 1 && model.status == .permissionRequired,
          "foreground opt-in requests permission once")
    driver.authorization = .authorized
    model.authorizationDidChange()
    let generation = driver.requestedGenerations.last
    check(model.status == .locating && generation != nil, "authorized foreground context requests one location")
    if let generation {
        await model.receiveFix(LocationFix(latitude: 47.6062, longitude: -122.3321, accuracyMeters: 12,
                                           timestamp: now), generation: generation, now: now)
    }
    let message = model.message("Find a nearby cafe.", now: now)
    check(model.status == .ready && message.contains("Find a nearby cafe.") && message.contains("Location context"),
          "an opted-in ordinary message includes the prepared coarse context")
    check(model.message("/status", now: now) == "/status", "slash commands never receive location context")
    driver.authorization = .denied
    check(model.message("keep this exact", now: now) == "keep this exact"
          && model.snapshot == nil && model.status == .denied,
          "revoked permission clears an old snapshot before the next message")
    model.setEnabled(false)
    check(model.snapshot == nil && !model.enabled && model.message("plain", now: now) == "plain",
          "disabling location clears context and preserves the draft text")
}

/// Sends through the actual demo Gateway so the opt-in context reaches the normal `chat.send` path.
@MainActor
func runDemoLocationContextChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    let model = LocationContextModel(defaults: defaults)
    let driver = LocationContextCheckDriver(.authorized)
    model.configure(driver: driver)
    model.setActive(true)
    model.setEnabled(true)
    gateway.locationContext = model
    guard let generation = driver.requestedGenerations.last else {
        check(false, "demo location context got a location request")
        return
    }
    let now = Date()
    await model.receiveFix(LocationFix(latitude: 47.6062, longitude: -122.3321, accuracyMeters: 12,
                                       timestamp: now), generation: generation, now: now)

    gateway.start()
    gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("demo location context") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "the built-in demo connects for the location opt-in send check")
    guard connected else { return }

    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let loaded = await waitFor("demo location chat history") { chat.hasLoaded }
    check(loaded, "the demo chat is ready before the location-context send")
    guard loaded else { return }
    check(chat.items.contains { $0.plainText.contains("fictional Boston example")
                               && $0.plainText.contains("42.36, -71.06 ±2000m") },
          "the demo welcome showcases a clearly fictional approximate context sample")
    let marker = "location-context-demo-\(UUID().uuidString)"
    let outcome = await chat.sendMessage(marker, includeLocation: true)
    if case .sent = outcome {
        check(true, "the demo accepts the context-enabled message")
    } else {
        check(false, "the demo accepts the context-enabled message (\(outcome))")
    }
    let committed = await waitFor("demo committed location message", timeout: 20) {
        chat.items.contains { $0.role == .user && !$0.isPending && $0.plainText.contains(marker) }
    }
    check(committed, "the demo commits the context-enabled user message")
    let sent = chat.items.last { $0.role == .user && $0.plainText.contains(marker) }
    check(sent?.plainText.contains("Location context (approximate, shared by Pincer):") == true
          && sent?.plainText.contains("47.6062") == false,
          "the committed demo message carries only the prepared coarse location note")
}
