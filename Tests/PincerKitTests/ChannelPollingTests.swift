import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Channel status staleness fallback (#273)")
struct ChannelPollingTests {
    @MainActor private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
    }

    @Test func freshSuccessfulStatusDoesNotPollAgain() async {
        let clock = Clock()
        var requests = 0
        let model = ChannelsModel(now: { clock.date }) { method, _ in
            #expect(method == ChannelsModel.statusMethod)
            requests += 1
            return ChannelFixtures.status
        }
        await model.load()
        #expect(model.snapshot != nil)
        await model.poll()
        #expect(requests == 1)
    }

    @Test func fallbackStartsAtThirtySecondsAndResetsAfterSuccess() async {
        let clock = Clock()
        var requests = 0
        let model = ChannelsModel(now: { clock.date }) { _, _ in
            requests += 1
            return ChannelFixtures.status
        }
        await model.poll()
        #expect(requests == 1)
        let initial = clock.date
        clock.date = initial.addingTimeInterval(29.999)
        await model.poll()
        #expect(requests == 1)
        clock.date = initial.addingTimeInterval(30)
        await model.poll()
        #expect(requests == 2)
        await model.poll()
        #expect(requests == 2)
    }

    @Test func manualRefreshAndProbeBypassFreshnessAndResetForgetsIt() async {
        let clock = Clock()
        var probes: [Bool] = []
        let model = ChannelsModel(now: { clock.date }) { _, params in
            probes.append(params["probe"]?.bool ?? false)
            return ChannelFixtures.status
        }
        await model.load()
        await model.refresh()
        await model.probe()
        #expect(probes == [false, false, true])
        await model.poll()
        #expect(probes.count == 3)
        model.reset()
        await model.poll()
        #expect(probes == [false, false, true, false])
    }

    @Test func failedAndMalformedResponsesDoNotPostponeTheFallback() async {
        let clock = Clock()
        var requests = 0
        let model = ChannelsModel(now: { clock.date }) { _, _ in
            requests += 1
            if requests == 2 { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Offline", details: nil) }
            if requests == 3 { return .array([]) }
            return ChannelFixtures.status
        }
        await model.load()
        clock.date += 30
        await model.poll()
        #expect(requests == 2 && model.loadState.error != nil)
        await model.poll()
        #expect(requests == 3 && model.loadState.error != nil)
        await model.poll()
        #expect(requests == 4 && model.loadState == .idle)
        await model.poll()
        #expect(requests == 4)
    }

    @Test func pollDoesNotOverlapAnInflightLoad() async {
        let entered = Gate()
        let release = Gate()
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(15))
                await entered.open()
                await release.open()
            } catch { }
        }
        defer { watchdog.cancel() }
        var requests = 0
        let model = ChannelsModel { _, _ in
            requests += 1
            await entered.open()
            await release.wait()
            return ChannelFixtures.status
        }
        let loading = Task { await model.load() }
        await entered.wait()
        await model.poll()
        #expect(requests == 1)
        await release.open()
        await loading.value
    }
}
