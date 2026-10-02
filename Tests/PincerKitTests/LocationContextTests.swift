import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class LocationContextTestDriver: LocationContextDriver {
    var authorization: LocationAuthorization
    var authorizationRequests = 0
    var requestedGenerations: [Int] = []
    var stopCount = 0

    init(_ authorization: LocationAuthorization) { self.authorization = authorization }

    func requestAuthorization() { self.authorizationRequests += 1 }
    func requestLocation(generation: Int) { self.requestedGenerations.append(generation) }
    func stop() { self.stopCount += 1 }
}

@MainActor
@Suite("Location context")
struct LocationContextTests {
    @Test func preparedSnapshotKeepsProviderCoordinatesAccuracyAndFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fix = LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 18,
                              timestamp: now)
        let snapshot = try #require(LocationContextSnapshot.prepare(fix, now: now))

        #expect(snapshot.coordinates == "37.774900, -122.419400")
        #expect(snapshot.accuracy == "±18m")
        #expect(snapshot.observed == now.formatted(.iso8601))
        #expect(snapshot.context.contains(snapshot.coordinates))
        #expect(snapshot.context.contains("reported accuracy ±18m"))
        #expect(snapshot.context.count < 180, "the disclosed location note stays bounded")
        #expect(snapshot.isFresh(at: now.addingTimeInterval(300)))
        #expect(!snapshot.isFresh(at: now.addingTimeInterval(300.001)))
        #expect(!snapshot.isFresh(at: now.addingTimeInterval(-0.001)), "future snapshots are never fresh")

        let stale = LocationFix(latitude: 37.7, longitude: -122.4, accuracyMeters: 5,
                                timestamp: now.addingTimeInterval(-300.001))
        let future = LocationFix(latitude: 37.7, longitude: -122.4, accuracyMeters: 5,
                                 timestamp: now.addingTimeInterval(0.001))
        let inaccurate = LocationFix(latitude: 37.7, longitude: -122.4, accuracyMeters: 50_000.001,
                                     timestamp: now)
        let invalid = LocationFix(latitude: .nan, longitude: -122.4, accuracyMeters: 5, timestamp: now)
        #expect(LocationContextSnapshot.prepare(stale, now: now) == nil)
        #expect(LocationContextSnapshot.prepare(future, now: now) == nil)
        #expect(LocationContextSnapshot.prepare(inaccurate, now: now) == nil)
        #expect(LocationContextSnapshot.prepare(invalid, now: now) == nil)

        let broadAccuracy = LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 4_000,
                                        timestamp: now)
        #expect(LocationContextSnapshot.prepare(broadAccuracy, now: now)?.accuracy == "±4000m",
                "the device's reported accuracy is preserved without a quantization margin")
    }

    @Test func locationSnapshotSurvivesOutboxCodableRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fix = LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 18,
                              timestamp: now)
        let snapshot = try #require(LocationContextSnapshot.prepare(fix, now: now))
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(LocationContextSnapshot.self, from: data)
        #expect(restored == snapshot, "queued context is stable across persistence and retry")
    }

    @Test func permissionAndLocationWorkWaitForForegroundOptIn() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let model = LocationContextModel(defaults: scratch.defaults)
        let driver = LocationContextTestDriver(.notDetermined)
        model.configure(driver: driver)
        model.setEnabled(true)

        #expect(model.enabled && scratch.defaults.bool(forKey: LocationContextModel.enabledKey))
        #expect(driver.authorizationRequests == 0 && driver.requestedGenerations.isEmpty,
                "opt-in doesn't prompt or locate until a foreground window is active")

        model.setActive(true)
        #expect(driver.authorizationRequests == 1 && model.status == .permissionRequired)
        driver.authorization = .authorized
        model.authorizationDidChange()
        let generation = try #require(driver.requestedGenerations.last)
        #expect(model.status == .locating)

        let now = Date()
        await model.receiveFix(LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 18,
                                           timestamp: now), generation: generation, now: now)
        #expect(model.status == .ready && model.snapshot != nil)
        let context = try #require(model.context(forMessage: "What is nearby?", now: now))
        #expect(context.coordinates == "37.774900, -122.419400")
        #expect(model.context(forMessage: "/help", now: now) == nil, "slash commands do not receive context")
        #expect(model.context(forMessage: " !reset", now: now) == nil, "bang commands do not receive context")

        model.setActive(false)
        #expect(model.snapshot == nil && driver.stopCount > 0,
                "backgrounding clears the prepared context and stops an in-flight location request")
        #expect(model.context(forMessage: "ordinary text", now: now) == nil)
    }

    @Test func sendingUsesCachedContextBeforeStartingARefresh() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let model = LocationContextModel(defaults: scratch.defaults)
        let driver = LocationContextTestDriver(.authorized)
        model.configure(driver: driver)
        model.setActive(true)
        model.setEnabled(true)
        let generation = try #require(driver.requestedGenerations.last)
        let now = Date()
        await model.receiveFix(LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 18,
                                           timestamp: now.addingTimeInterval(-40)),
                               generation: generation, now: now)
        let requests = driver.requestedGenerations.count
        let context = try #require(model.context(forMessage: "Find a nearby cafe.", now: now))
        #expect(context.coordinates == "37.774900, -122.419400", "a recent cached fix is usable while it refreshes")
        #expect(driver.requestedGenerations.count == requests,
                "sending returns before platform acquisition setup, without waiting for a new fix")
        #expect(await eventually { driver.requestedGenerations.count == requests + 1 },
                "the foreground refresh still starts after the send path returns")
    }

    @Test func disablingIgnoresLateFixAndPersistsOptOut() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let model = LocationContextModel(defaults: scratch.defaults)
        let driver = LocationContextTestDriver(.authorized)
        model.configure(driver: driver)
        model.setActive(true)
        model.setEnabled(true)
        let generation = try #require(driver.requestedGenerations.last)

        model.setEnabled(false)
        let now = Date()
        await model.receiveFix(LocationFix(latitude: 51.5, longitude: -0.1, accuracyMeters: 25,
                                           timestamp: now), generation: generation, now: now)
        #expect(!model.enabled && !scratch.defaults.bool(forKey: LocationContextModel.enabledKey))
        #expect(model.status == .off && model.snapshot == nil)
        #expect(model.context(forMessage: "keep this exact", now: now) == nil)

        let restored = LocationContextModel(defaults: scratch.defaults)
        #expect(!restored.enabled && restored.status == .off, "the opt-out survives model recreation")

        model.setEnabled(true)
        let freshGeneration = try #require(driver.requestedGenerations.last)
        #expect(freshGeneration > generation && model.status == .locating)
        await model.receiveFix(LocationFix(latitude: 51.5, longitude: -0.1, accuracyMeters: 25,
                                           timestamp: now), generation: generation, now: now)
        #expect(model.status == .locating && model.snapshot == nil,
                "a late fix from before opt-out cannot satisfy the new request")
        await model.receiveFix(LocationFix(latitude: 51.5, longitude: -0.1, accuracyMeters: 25,
                                           timestamp: now), generation: freshGeneration, now: now)
        #expect(model.status == .ready && model.snapshot != nil)
    }

    @Test func denialAndFailureAreTerminalWithoutWaitingOnTheTimeout() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let deniedModel = LocationContextModel(defaults: scratch.defaults)
        let denied = LocationContextTestDriver(.denied)
        deniedModel.configure(driver: denied)
        deniedModel.setActive(true)
        deniedModel.setEnabled(true)
        #expect(deniedModel.status == .denied && denied.requestedGenerations.isEmpty)

        let failedModel = LocationContextModel(defaults: scratch.defaults)
        let authorized = LocationContextTestDriver(.authorized)
        failedModel.configure(driver: authorized)
        failedModel.setActive(true)
        failedModel.setEnabled(true)
        let generation = try #require(authorized.requestedGenerations.last)
        failedModel.receiveFailure(generation: generation)
        #expect(failedModel.status == .unavailable && failedModel.snapshot == nil)
        failedModel.receiveFailure(generation: generation - 1)
        #expect(failedModel.status == .unavailable, "an unrelated stale failure can't change state")
    }

    @Test func revokedPermissionDropsReadySnapshotAndPreservesMessage() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let model = LocationContextModel(defaults: scratch.defaults)
        let driver = LocationContextTestDriver(.authorized)
        model.configure(driver: driver)
        model.setActive(true)
        model.setEnabled(true)
        let generation = try #require(driver.requestedGenerations.last)
        let now = Date()
        await model.receiveFix(LocationFix(latitude: 40.7128, longitude: -74.0060, accuracyMeters: 15,
                                           timestamp: now), generation: generation, now: now)
        #expect(model.snapshot != nil && model.status == .ready)

        driver.authorization = .denied
        #expect(model.context(forMessage: "keep the user's text", now: now) == nil)
        #expect(model.snapshot == nil && model.status == .denied,
                "revoking permission clears the old fix before any message can disclose it")
    }

    @Test func chatSendOptInIsExplicitAndQueuedTextKeepsItsPreparedSnapshot() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        let model = LocationContextModel(defaults: scratch.defaults)
        let driver = LocationContextTestDriver(.authorized)
        model.configure(driver: driver)
        model.setActive(true)
        model.setEnabled(true)
        let firstGeneration = try #require(driver.requestedGenerations.last)
        let firstFixTime = Date()
        await model.receiveFix(LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 18,
                                           timestamp: firstFixTime), generation: firstGeneration, now: firstFixTime)
        gateway.locationContext = model
        let key = "agent:main:dashboard:trip"
        let chat = gateway.chat(for: key)

        let defaultText = "No location by default \(UUID().uuidString)"
        #expect(await chat.sendMessage(defaultText) == .queued)
        #expect(gateway.outbox.entries(for: key).last?.text == defaultText
                && gateway.outbox.entries(for: key).last?.locationContext == nil,
                "the default send path never appends opted-in context")

        let firstMarker = "first snapshot \(UUID().uuidString)"
        #expect(await chat.sendMessage(firstMarker, includeLocation: true) == .queued)
        let firstEntry = try #require(gateway.outbox.entries(for: key).last { $0.text.contains(firstMarker) })
        #expect(firstEntry.text == firstMarker)
        #expect(firstEntry.locationContext?.coordinates == "37.774900, -122.419400"
                && firstEntry.locationContext?.accuracy == "±18m")

        #expect(await chat.sendMessage("  /help", includeLocation: true) == .queued)
        #expect(gateway.outbox.entries(for: key).last?.text == "/help"
                && gateway.outbox.entries(for: key).last?.locationContext == nil,
                "leading whitespace cannot route a command through location disclosure")

        model.setActive(false)
        model.setActive(true)
        let secondGeneration = try #require(driver.requestedGenerations.last)
        #expect(secondGeneration > firstGeneration)
        let secondFixTime = Date()
        await model.receiveFix(LocationFix(latitude: 51.5072, longitude: -0.1276, accuracyMeters: 20,
                                           timestamp: secondFixTime), generation: secondGeneration, now: secondFixTime)
        let secondMarker = "second snapshot \(UUID().uuidString)"
        #expect(await chat.sendMessage(secondMarker, includeLocation: true) == .queued)

        let entries = gateway.outbox.entries(for: key)
        let savedFirst = try #require(entries.first { $0.id == firstEntry.id })
        let savedSecond = try #require(entries.last { $0.text.contains(secondMarker) })
        #expect(savedFirst.text == firstMarker
                && savedFirst.locationContext?.coordinates == "37.774900, -122.419400",
                "a queued send keeps its prepared location context separately from authored text")
        #expect(savedSecond.text == secondMarker
                && savedSecond.locationContext?.coordinates == "51.507200, -0.127600",
                "a later location update applies only to later opted-in sends")
    }

    @Test func optedInLocationDoesNotRewriteAuthoredOrOptimisticMessageText() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        let model = LocationContextModel(defaults: scratch.defaults)
        let driver = LocationContextTestDriver(.authorized)
        model.configure(driver: driver)
        model.setActive(true)
        model.setEnabled(true)
        let generation = try #require(driver.requestedGenerations.last)
        let now = Date()
        await model.receiveFix(LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 18,
                                           timestamp: now), generation: generation, now: now)
        gateway.locationContext = model
        let key = "agent:main:dashboard:location-display"
        let chat = gateway.chat(for: key)
        let authored = "Location context (approximate, shared by Pincer): 📍 37.7749, -122.4194 ±18m; observed 2026-10-02T12:00:00Z"

        #expect(await chat.sendMessage(authored, includeLocation: true) == .queued)
        let entry = try #require(gateway.outbox.entries(for: key).last)
        let optimistic = try #require(chat.items.last { $0.isPending })
        #expect(entry.text == authored, "the queue retains only the user's authored message body")
        #expect(entry.locationContext?.coordinates == "37.774900, -122.419400")
        #expect(optimistic.plainText == authored, "the optimistic bubble keeps authored location prose verbatim")
    }

    @Test func projectedHistoryPreservesAuthoredLocationLookalikes() throws {
        let authored = "Location context (approximate, shared by Pincer): 📍 37.7749, -122.4194 ±18m; observed 2026-10-02T12:00:00Z"
        let fixture = Fixtures.json(#"{"role":"user","content":"Location context (approximate, shared by Pincer): 📍 37.7749, -122.4194 ±18m; observed 2026-10-02T12:00:00Z","__openclaw":{"id":"projected-location","workContext":{"snapshot":{"page":"Pincer location","detail":{"coordinates":"37.7749, -122.4194","accuracy":"±18m","observed":"2026-10-02T12:00:00Z"}},"text":"Location context (approximate, shared by Pincer): 📍 37.7749, -122.4194 ±18m; observed 2026-10-02T12:00:00Z"}}}"#)
        let projected = try #require(ChatItem(fixture, fallbackIndex: 0))

        #expect(projected.plainText == authored,
                "history display uses the Gateway's metadata-backed original-text projection, not footer matching")

        let ordinary = try #require(ChatItem(Fixtures.json(#"{"role":"user","content":"I pasted this location context (approximate, shared by Pincer): 📍 37.7749, -122.4194 ±18m; observed 2026-10-02T12:00:00Z","__openclaw":{"id":"authored-location-lookalike"}}"#), fallbackIndex: 1))
        #expect(ordinary.plainText == "I pasted this location context (approximate, shared by Pincer): 📍 37.7749, -122.4194 ±18m; observed 2026-10-02T12:00:00Z")
    }
}
