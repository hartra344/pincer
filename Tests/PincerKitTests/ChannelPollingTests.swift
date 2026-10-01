import Testing
@testable import PincerKit

@MainActor
@Suite("Channel status staleness fallback (#273)")
struct ChannelPollingTests {
    @Test func freshSuccessfulStatusDoesNotPollAgain() async {
        var requests = 0
        let model = ChannelsModel { method, _ in
            #expect(method == ChannelsModel.statusMethod)
            requests += 1
            return ChannelFixtures.status
        }
        await model.load()
        #expect(model.snapshot != nil)
        await model.poll()
        #expect(requests == 1)
    }
}
