import Foundation
import Testing
@testable import PincerKit

/// #1074: backgrounding iOS keeps the Gateway connections open on background time.
@MainActor
final class FakeBackgroundTime {
    private(set) var begun: [String] = []
    private(set) var ended = 0
    private var expire: (@MainActor () -> Void)?

    var begin: BackgroundConnectionGrace.Begin {
        { [self] name, expired in
            self.begun.append(name)
            self.expire = expired
            return { [self] in self.ended += 1 }
        }
    }

    /// iOS ran out of background time.
    func runOut() {
        let expire = self.expire
        self.expire = nil
        expire?()
    }
}

@MainActor
@Suite("Background connection grace")
struct BackgroundConnectionGraceTests {
    @Test func backgroundBeginsTimeOnceAndForegroundEndsIt() {
        let time = FakeBackgroundTime()
        let grace = BackgroundConnectionGrace(begin: time.begin)
        grace.enterBackground()
        grace.enterBackground()
        #expect(time.begun == [BackgroundConnectionGrace.activityName] && grace.isHeld && !grace.expired)
        grace.enterForeground()
        #expect(time.ended == 1 && !grace.isHeld)
        grace.enterForeground()
        #expect(time.ended == 1, "ending twice is a no-op")
    }

    @Test func expiryRunsOnExpireOnceUntilForeground() {
        let time = FakeBackgroundTime()
        let grace = BackgroundConnectionGrace(begin: time.begin)
        var expiries = 0
        grace.onExpire = { expiries += 1 }
        grace.enterBackground()
        time.runOut()
        #expect(expiries == 1 && grace.expired && !grace.isHeld)
        #expect(time.ended == 1, "expiry ends the task itself: its end closure may be the task's only owner")
        grace.enterBackground()
        #expect(time.begun.count == 1, "no new background time is asked for until the app came back")
        grace.enterForeground()
        #expect(!grace.expired && time.ended == 1, "returning doesn't end the expired task again")
    }

    @Test func lateExpiryAfterReturnIsIgnored() {
        let time = FakeBackgroundTime()
        let grace = BackgroundConnectionGrace(begin: time.begin)
        var expiries = 0
        grace.onExpire = { expiries += 1 }
        grace.enterBackground()
        grace.enterForeground()
        time.runOut()
        #expect(expiries == 0 && !grace.expired)
    }

    @Test func appModelHoldsBackgroundTimeWhileInBackground() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        let time = FakeBackgroundTime()
        app.connectionGrace.begin = time.begin
        app.appIsInBackground = true
        #expect(app.connectionGrace.isHeld && time.begun.count == 1)
        app.appIsInBackground = false
        #expect(!app.connectionGrace.isHeld && time.ended == 1)
    }

    /// The repro: backgrounding used to close device mode's node socket at once.
    @Test func deviceNodeStaysConnectedUntilBackgroundTimeRunsOut() async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demoInstantPacing(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        gateway.deviceNode.handler = FakeNodeHandler()
        gateway.deviceNode.followsAppLifecycle = true
        gateway.start()
        defer {
            gateway.stop()
            scratch.remove()
        }
        #expect(await eventually(timeout: .seconds(10)) { gateway.state.isConnected })
        await gateway.deviceNode.update(DeviceModeSettings(enabled: true))
        #expect(await eventually(timeout: .seconds(10)) { gateway.deviceNode.status == .active })
        let epoch = gateway.connectionEpoch

        gateway.appIsInBackground = true
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gateway.deviceNode.status == .active, "backgrounding keeps the node connected (\(gateway.deviceNode.status))")

        gateway.appIsInBackground = false
        gateway.reconnectIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gateway.deviceNode.status == .active && gateway.connectionEpoch == epoch,
                "a quick return reuses both connections")

        gateway.appIsInBackground = true
        gateway.backgroundTimeExpired()
        #expect(gateway.deviceNode.status == .paused, "out of background time → paused")
        #expect(gateway.state.isConnected, "the operator connection is left to iOS")

        gateway.appIsInBackground = false
        #expect(await eventually(timeout: .seconds(10)) { gateway.deviceNode.status == .active }, "returning resumes the node")
    }
}
