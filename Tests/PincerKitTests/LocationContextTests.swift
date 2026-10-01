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
    @Test func preparedSnapshotIsCoarseBoundedAndFreshnessChecked() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fix = LocationFix(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 18,
                              timestamp: now)
        let snapshot = try #require(LocationContextSnapshot.prepare(fix, now: now))

        #expect(snapshot.context.contains("37.78, -122.42"))
        #expect(snapshot.context.contains("±2000m"))
        #expect(!snapshot.context.contains("37.7749") && !snapshot.context.contains("-122.4194"))
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
        #expect(LocationContextSnapshot.prepare(broadAccuracy, now: now)?.context.contains("±5600m") == true,
                "quantization uncertainty is added to the device's reported accuracy")
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
        let text = model.message("What is nearby?", now: now)
        #expect(text.hasPrefix("What is nearby?\n\nLocation context (approximate, shared by Pincer):"))
        #expect(model.message("/help", now: now) == "/help", "commands keep their original text")

        model.setActive(false)
        #expect(model.snapshot == nil && driver.stopCount > 0,
                "backgrounding clears the prepared context and stops an in-flight location request")
        #expect(model.message("ordinary text", now: now) == "ordinary text")
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
        let text = model.message("Find a nearby cafe.", now: now)
        #expect(text.contains("37.78, -122.42"), "a recent cached fix is usable while it refreshes")
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
        #expect(model.message("keep this exact", now: now) == "keep this exact")

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
        #expect(model.message("keep the user's text", now: now) == "keep the user's text")
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
        #expect(gateway.outbox.entries(for: key).last?.text == defaultText,
                "the default send path never appends opted-in context")

        let firstMarker = "first snapshot \(UUID().uuidString)"
        #expect(await chat.sendMessage(firstMarker, includeLocation: true) == .queued)
        let firstEntry = try #require(gateway.outbox.entries(for: key).last { $0.text.contains(firstMarker) })
        #expect(firstEntry.text.contains("37.78, -122.42") && firstEntry.text.contains("Location context"))

        #expect(await chat.sendMessage("  /help", includeLocation: true) == .queued)
        #expect(gateway.outbox.entries(for: key).last?.text == "/help",
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
        #expect(savedFirst.text.contains("37.78, -122.42") && !savedFirst.text.contains("51.50, -0.12"),
                "a queued send keeps the exact coarse context the user saw when sending")
        #expect(savedSecond.text.contains("51.50, -0.12") && !savedSecond.text.contains("37.78, -122.42"),
                "a later location update applies only to later opted-in sends")
    }
}
