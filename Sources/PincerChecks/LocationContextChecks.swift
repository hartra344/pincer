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
    check(snapshot?.coordinates == "47.606200, -122.332100"
          && snapshot?.accuracy == "±12m"
          && snapshot?.context.contains("47.606200, -122.332100") == true,
          "location context preserves device coordinates and reported accuracy")
    check(snapshot?.isFresh(at: now.addingTimeInterval(300)) == true
          && snapshot?.isFresh(at: now.addingTimeInterval(301)) == false,
          "location context expires after five minutes")
    let conservative = LocationContextSnapshot.prepare(
        LocationFix(latitude: 47.6062, longitude: -122.3321, accuracyMeters: 4_000, timestamp: now), now: now)
    check(conservative?.accuracy == "±4000m",
          "reported uncertainty is not inflated by app-side rounding")
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
    let context = model.context(forMessage: "Find a nearby cafe.", now: now)
    check(model.status == .ready && context?.coordinates == "47.606200, -122.332100"
          && context?.accuracy == "±12m",
          "an opted-in ordinary message can capture the prepared context separately")
    check(model.context(forMessage: "/status", now: now) == nil
          && model.context(forMessage: "!reset", now: now) == nil,
          "slash and bang commands never receive location context")
    driver.authorization = .denied
    check(model.context(forMessage: "keep this exact", now: now) == nil
          && model.snapshot == nil && model.status == .denied,
          "revoked permission clears an old snapshot before the next message")
    model.setEnabled(false)
    check(model.snapshot == nil && !model.enabled && model.context(forMessage: "plain", now: now) == nil,
          "disabling location clears context and preserves the draft text")
}

/// Sends through the actual demo Gateway so the opt-in context reaches the normal `chat.send` path.
@MainActor
func runDemoLocationContextChecks() async {
    let tips = DemoGateway.thingsToTry(usedTool: false)
    check(tips.contains("context stays separate from your message text")
          && tips.contains("device's reported accuracy") && !tips.contains("visible location context"),
          "demo guidance describes separate context with device-reported accuracy")
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
    check(!chat.items.contains { $0.plainText.contains("Location context (approximate, shared by Pincer):") },
          "demo transcript bubbles do not expose the legacy location footer")
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
    check(sent?.plainText == marker,
          "the committed demo bubble contains only the authored message")
    let history = try? await gateway.connection.request("chat.history", [
        "sessionKey": .string("agent:main:main"), "limit": .number(20),
    ], timeout: 20)
    let rawUserMessage = history?["messages"]?.array?.first { message in
        guard message["role"]?.string == "user" else { return false }
        return message["content"]?.array?.contains { $0["text"]?.string == marker } == true
    }
    let captured = rawUserMessage?["__openclaw"]?["workContext"]?["snapshot"]?["selection"]?.string
    check(captured?.contains("47.606200, -122.332100") == true && captured?.contains("±12m") == true,
          "the Gateway receives the captured location in work-context metadata")
}
