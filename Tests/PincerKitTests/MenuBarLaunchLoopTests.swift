import Foundation
import Observation
import Testing
@testable import PincerKit

/// #119: the menu bar item froze the app at launch. `MenuBarExtra(isInserted:)` writes its binding back
/// on every app update, and a write that always lands posts `UserDefaults.didChangeNotification`,
/// which starts another update. So an unchanged setting must never be written. Also: building
/// `MenuBarInbox(app:now:)` in the label's body changes nothing it observes, and health dismissals
/// that don't change aren't written or pushed to `users.prefs`.
@MainActor
@Suite("Menu bar launch loop (#119)")
struct MenuBarLaunchLoopTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)
    static let channelIssue = GatewayHealthIssue(id: "channel:t:default", kind: .channel, title: "T (default)",
                                                 fingerprint: "state=not-connected")

    /// Runs `read` under observation tracking and returns a flag that `onChange` sets.
    final class Tripwire: @unchecked Sendable {
        var fired = false
    }

    static func track(_ read: () -> Void) -> Tripwire {
        let tripwire = Tripwire()
        withObservationTracking(read) { tripwire.fired = true }
        return tripwire
    }

    /// Everything the menu reads from one store, plus the dismissal state it must leave alone.
    static func readAll(_ store: GatewayStore) {
        _ = store.state
        _ = store.sessions
        _ = store.approvals
        _ = store.questions
        _ = store.agents
        _ = store.healthDismissals
        _ = store.health.dismissals
        _ = store.health.level(now: Self.now)
    }

    static func store(_ scratch: ScratchDefaults, dismissals: [String: String] = [:], synced: Bool = true) -> GatewayStore {
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none)
        if !dismissals.isEmpty { scratch.defaults.set(dismissals, forKey: "pincer.healthDismissals.\(profile.id.uuidString)") }
        // Marks users.prefs as synced, so a real change would push.
        scratch.defaults.set(synced, forKey: "pincer.healthDismissalsSynced.\(profile.id.uuidString)")
        return GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
    }

    // MARK: MenuBarSettings.setEnabled (the loop edge)

    /// Counts `UserDefaults.didChangeNotification` posts for one defaults instance.
    final class ChangeCounter: @unchecked Sendable {
        var count = 0
        var token: NSObjectProtocol?

        init(_ defaults: UserDefaults) {
            self.token = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
                self?.count += 1
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    @Test func setEnabledOnlyWritesChanges() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let settings = MenuBarSettings(defaults: scratch.defaults)
        let changes = ChangeCounter(scratch.defaults)
        defer { changes.stop() }
        // MenuBarExtra echoes `isInserted` back on every app update; a missing key already reads off.
        #expect(!settings.setEnabled(false) && scratch.defaults.object(forKey: MenuBarSettings.enabledKey) == nil)
        #expect(changes.count == 0, "turning off an unset setting posted didChange")
        #expect(settings.setEnabled(true) && settings.isEnabled)
        let afterOn = changes.count
        #expect(afterOn >= 1)
        for _ in 0..<50 { #expect(!settings.setEnabled(true)) }
        #expect(changes.count == afterOn, "echoing the same value posted didChange \(changes.count - afterOn) times")
        #expect(settings.setEnabled(false) && !settings.isEnabled && changes.count > afterOn)
        let afterOff = changes.count
        for _ in 0..<50 { settings.setEnabled(false) }
        #expect(changes.count == afterOff && scratch.defaults.object(forKey: MenuBarSettings.enabledKey) as? Bool == false)
    }

    @Test func setEnabledReadsWhatAnotherWriterStored() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        // Settings' toggle and ⌘-drag write the same key; a later echo of that value is a no-op.
        scratch.defaults.set(true, forKey: MenuBarSettings.enabledKey)
        let settings = MenuBarSettings(defaults: scratch.defaults)
        let changes = ChangeCounter(scratch.defaults)
        defer { changes.stop() }
        #expect(!settings.setEnabled(true) && changes.count == 0)
        #expect(MenuBarSettings(defaults: scratch.defaults).setEnabled(false) && !settings.isEnabled)
    }

    // MARK: GatewayStore.health (hardening)

    @Test func healthIsBuiltWithTheStore() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = Self.store(scratch, dismissals: [Self.channelIssue.id: "always"])
        // A lazy var shows up as `$__lazy_storage_$_health` and stays nil until something reads it,
        // which put its creation inside the menu bar label's body.
        let lazy = Mirror(reflecting: store).children.contains { child in
            guard let label = child.label, label.contains("lazy_storage"), label.hasSuffix("health") else { return false }
            if case Optional<Any>.none = child.value { return true }
            return false
        }
        #expect(!lazy, "GatewayStore.health exists before the first read")
        let first = store.health
        #expect(first === store.health && first.dismissals == store.healthDismissals)
        #expect(first.dismissals == [Self.channelIssue.id: "always"])
    }

    @Test func readingHealthChangesNothing() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = Self.store(scratch, dismissals: ["queue:q": "until:count=1"])
        let tripwire = Self.track { Self.readAll(store) }
        Self.readAll(store)
        #expect(!tripwire.fired)
        #expect(store.healthDismissalPushes == 0)
    }

    // MARK: MenuBarInbox(app:now:)

    @Test func buildingTheInboxHasNoSideEffects() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let home = GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none)
        let work = GatewayProfile(name: "Work", url: "ws://127.0.0.1:9", authMode: .none)
        let dismissals = ["queue:q": "until:count=1", "plugin:gone": "always"]
        scratch.defaults.set(dismissals, forKey: "pincer.healthDismissals.\(home.id.uuidString)")
        scratch.defaults.set(true, forKey: "pincer.healthDismissalsSynced.\(home.id.uuidString)")
        GatewayProfileStore.save([home, work], to: scratch.defaults)
        // Loaded, not added: nothing connects.
        let app = AppModel(defaults: scratch.defaults)
        #expect(app.gateways.count == 2)
        let before = scratch.defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("pincer.") }.mapValues { "\($0)" }

        // What the menu bar label's body does, twice: the second build must not invalidate the first.
        var first = MenuBarInbox()
        let tripwire = Self.track { first = MenuBarInbox(app: app, now: Self.now) }
        let second = MenuBarInbox(app: app, now: Self.now)
        #expect(!tripwire.fired, "building the inbox changed state it reads")
        #expect(first.gateways.map(\.title) == second.gateways.map(\.title) && first.badgeText == second.badgeText)

        // Nothing the menu doesn't read changes either, including after queued work runs.
        let watched = Self.track { for gateway in app.gateways { Self.readAll(gateway) } }
        _ = MenuBarInbox(app: app, now: Self.now)
        _ = MenuBarInbox(app: app)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!watched.fired)
        for gateway in app.gateways {
            #expect(gateway.healthDismissalPushes == 0, "\(gateway.profile.name) pushed users.prefs")
            #expect(gateway.health.dismissals == gateway.healthDismissals)
        }
        #expect(app.gateways.first?.healthDismissals == dismissals)
        let after = scratch.defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("pincer.") }.mapValues { "\($0)" }
        #expect(after == before, "building the inbox wrote defaults")
    }

    // MARK: Idempotent dismissals

    @Test func dismissingTwiceWritesOnce() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = Self.store(scratch)
        var synced: [[String: String?]] = []
        let forward = store.health.onDismissalsChanged
        store.health.onDismissalsChanged = { synced.append($0); forward?($0) }
        store.health.dismiss(Self.channelIssue)
        #expect(store.healthDismissals == [Self.channelIssue.id: "until:state=not-connected"] && synced.count == 1)

        let tripwire = Self.track { _ = store.healthDismissals; _ = store.health.dismissals }
        store.health.dismiss(Self.channelIssue)
        #expect(!tripwire.fired, "dismissing an already dismissed issue wrote the dismissals again")
        #expect(synced.count == 1, "dismissing an already dismissed issue reported a change (\(synced))")
        store.health.restore(id: "channel:never:dismissed")
        #expect(!tripwire.fired && synced.count == 1)
    }

    @Test func applyingTheSameDismissalsTwiceIsANoOp() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = Self.store(scratch)
        let changes: [String: String?] = ["queue:q": "until:count=1", "plugin:w": "always"]
        store.applyHealthDismissals(changes)
        #expect(store.healthDismissals == ["queue:q": "until:count=1", "plugin:w": "always"])
        #expect(store.health.dismissals == store.healthDismissals)
        #expect(store.healthDismissalPushes == 1)

        let tripwire = Self.track { _ = store.healthDismissals; _ = store.health.dismissals }
        store.applyHealthDismissals(changes)
        store.applyHealthDismissals(["queue:q": "until:count=1"])
        store.applyHealthDismissals(["heartbeat:late": nil])
        store.applyHealthDismissals([:])
        #expect(!tripwire.fired, "no-op changes wrote healthDismissals")
        #expect(store.healthDismissalPushes == 1, "no-op changes pushed users.prefs")

        store.applyHealthDismissals(["plugin:w": nil])
        #expect(tripwire.fired && store.healthDismissals == ["queue:q": "until:count=1"])
        #expect(store.health.dismissals == store.healthDismissals && store.healthDismissalPushes == 2)
    }

    @Test func assigningEqualDismissalsIsNotAChange() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = Self.store(scratch, dismissals: ["queue:q": "until:count=1"])
        let tripwire = Self.track { _ = store.health.dismissals }
        store.healthDismissals = ["queue:q": "until:count=1"]
        #expect(!tripwire.fired, "an equal pull rewrote health.dismissals")
        #expect(store.healthDismissalPushes == 0)
    }

    // MARK: GatewayHealthModel pruning

    @Test func pruningNothingReportsNothing() {
        let dismissals = [Self.channelIssue.id: "until:state=not-connected", "plugin:gone": "always"]
        let model = GatewayHealthModel(dismissals: dismissals) { _, _ in .null }
        var synced: [[String: String?]] = []
        model.onDismissalsChanged = { synced.append($0) }
        let tripwire = Self.track { _ = model.dismissals }
        // Still reported, so the until-changed entry stays; `always` stays regardless.
        for _ in 0..<3 {
            model.handle(event: "health", payload: Fixtures.json(#"{"channels":{"t":{"running":true,"connected":false}}}"#))
            model.seed(snapshot: ["health": Fixtures.json(#"{"channels":{"t":{"running":true,"connected":false}}}"#)])
        }
        #expect(model.dismissals == dismissals && synced.isEmpty && !tripwire.fired)
        #expect(model.level == .healthy)
    }

    @Test func pruningWithNoDismissalsReportsNothing() {
        let model = GatewayHealthModel { _, _ in .null }
        var calls = 0
        model.onDismissalsChanged = { _ in calls += 1 }
        let tripwire = Self.track { _ = model.dismissals }
        model.handle(event: "health", payload: Fixtures.json(#"{"ok":true}"#))
        model.handle(event: "heartbeat", payload: ["ts": .number(Date().timeIntervalSince1970 * 1000), "status": "ok-token"])
        #expect(calls == 0 && !tripwire.fired)
    }

    @Test func dismissingAnAlreadyDismissedIssueOnTheModelReportsNothing() {
        let model = GatewayHealthModel { _, _ in .null }
        model.handle(event: "health", payload: Fixtures.json(#"{"plugins":{"errors":[{"id":"w","error":"bad manifest"}]}}"#))
        var synced: [[String: String?]] = []
        model.onDismissalsChanged = { synced.append($0) }
        let issue = model.activeIssues[0]
        model.dismiss(issue, always: true)
        #expect(synced.count == 1)
        let tripwire = Self.track { _ = model.dismissals }
        model.dismiss(issue, always: true)
        #expect(synced.count == 1 && !tripwire.fired)
        // A different value is a real change.
        model.dismiss(issue)
        #expect(synced.count == 2 && tripwire.fired && model.dismissals[issue.id] == "until:\(issue.fingerprint)")
    }

    // MARK: Time (acceptance #9)

    /// With no `Date()` in body, the menu is rebuilt with a later `now` on a tick. The same store
    /// contents at a later `now` must drop what expired, and update the badge and alert icon.
    @Test func laterNowDropsExpiredApprovalsAndQuestions() {
        let nowMs = Self.now.timeIntervalSince1970 * 1000
        let approval = ExecApproval(Fixtures.json(#"{"id":"a","request":{"command":"ls"},"expiresAtMs":\#(nowMs + 30_000)}"#))!
        let forever = ExecApproval(Fixtures.json(#"{"id":"b","request":{"command":"pwd"}}"#))!
        let question = QuestionPrompt(Fixtures.json(#"""
        {"id":"q","status":"pending","expiresAtMs":\#(nowMs + 45_000),"questions":[{"questionId":"q","header":"H","question":"Why?","options":[]}]}
        """#))!
        let input = MenuBarInbox.GatewayInput(name: "Home", state: .connected, approvals: [approval, forever], questions: [question])
        let at = { (seconds: Double) in MenuBarInbox.build([input], now: Self.now.addingTimeInterval(seconds)) }
        #expect(at(0).needsYouCount == 3 && at(0).badgeText == "3")
        #expect(at(31).needsYou.map(\.title) == ["Approve: pwd", "Question: Why?"] && at(31).badgeText == "2")
        #expect(at(46).needsYou.map(\.title) == ["Approve: pwd"] && at(46).badgeText == "1")
        let onlyExpiring = MenuBarInbox.GatewayInput(name: "Home", state: .connected, approvals: [approval], questions: [question])
        let later = MenuBarInbox.build([onlyExpiring], now: Self.now.addingTimeInterval(60))
        // needsYouCount drives the alert icon; at zero the plain icon and no badge.
        #expect(later.needsYouCount == 0 && later.badgeText == nil && later.isCaughtUp)
    }

    /// The health level (Degraded) also depends on `now`: a heartbeat that stops arriving goes late.
    @Test func laterNowMakesAMissedHeartbeatDegraded() {
        let model = GatewayHealthModel { _, _ in .null }
        model.handle(event: "health", payload: Fixtures.json(#"{"heartbeatSeconds":60,"heartbeatEnabled":true}"#))
        model.handle(event: "heartbeat", payload: ["ts": .number(Self.now.timeIntervalSince1970 * 1000), "status": "ok-token"])
        #expect(model.level(now: Self.now.addingTimeInterval(60)) == .healthy)
        #expect(model.level(now: Self.now.addingTimeInterval(121)) == .degraded)
        let status = { (level: GatewayHealthLevel) in MenuBarInbox.statusText(state: .connected, healthLevel: level).text }
        #expect(status(model.level(now: Self.now.addingTimeInterval(121))) == "Degraded")
    }

    /// Through the store, as the menu builds it: the same app at a later `now` drops an expired
    /// approval without anything else changing, and building at either time has no side effects.
    @Test func inboxFromTheAppFollowsNow() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        let tripwire = Self.track {
            _ = MenuBarInbox(app: app, now: Self.now)
            _ = MenuBarInbox(app: app, now: Self.now.addingTimeInterval(3600))
        }
        #expect(!tripwire.fired)
        #expect(MenuBarInbox(app: app, now: Self.now).gateways.map(\.text) == MenuBarInbox(app: app, now: Self.now.addingTimeInterval(3600)).gateways.map(\.text))
    }

    // MARK: MenuBarClock (acceptance #9)

    @Test func clockOnlyMovesForward() {
        let clock = MenuBarClock(now: Self.now)
        let tripwire = Self.track { _ = clock.now }
        clock.tick(Self.now)
        clock.tick(Self.now.addingTimeInterval(-5))
        #expect(!tripwire.fired && clock.now == Self.now, "a tick that doesn't advance must not invalidate the menu")
        clock.tick(Self.now.addingTimeInterval(30))
        #expect(tripwire.fired && clock.now == Self.now.addingTimeInterval(30))
    }

    @Test func clockTicksOnItsIntervalAndStops() async {
        #expect(MenuBarClock.interval <= .seconds(60), "expiries show within about a minute")
        let clock = MenuBarClock(now: .distantPast)
        clock.start(interval: .milliseconds(20))
        clock.start(interval: .milliseconds(20))
        #expect(clock.isRunning && clock.now > .distantPast, "start ticks at once")
        let first = clock.now
        for _ in 0..<50 where clock.now == first {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(clock.now > first, "the ticker moves now forward")
        clock.stop()
        #expect(!clock.isRunning)
        let stopped = clock.now
        try? await Task.sleep(for: .milliseconds(100))
        #expect(clock.now == stopped, "no ticks after stop")
    }

    /// End to end with the clock: an approval expires between ticks and leaves on the next one.
    @Test func aTickDropsAnExpiredApproval() {
        let nowMs = Self.now.timeIntervalSince1970 * 1000
        let approval = ExecApproval(Fixtures.json(#"{"id":"a","request":{"command":"ls"},"expiresAtMs":\#(nowMs + 10_000)}"#))!
        let input = MenuBarInbox.GatewayInput(name: "Home", state: .connected, approvals: [approval])
        let clock = MenuBarClock(now: Self.now)
        #expect(MenuBarInbox.build([input], now: clock.now).needsYouCount == 1)
        let tripwire = Self.track { _ = MenuBarInbox.build([input], now: clock.now) }
        clock.tick(Self.now.addingTimeInterval(TimeInterval(MenuBarClock.interval.components.seconds)))
        #expect(tripwire.fired && MenuBarInbox.build([input], now: clock.now).needsYouCount == 0)
    }
}
