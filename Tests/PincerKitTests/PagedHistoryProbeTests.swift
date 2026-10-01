import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Paged history probe")
struct PagedHistoryProbeTests {
    @Test func headlessLatestPagePagesIndependentlyOfWarmResidentChat() async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.start()
        defer {
            gateway.stop()
            scratch.remove()
        }

        let key = "agent:main:dashboard:trip"
        let connected = await eventually(timeout: .seconds(10)) {
            gateway.state.isConnected && gateway.sessions[key] != nil
        }
        #expect(connected, "the in-process demo connects with the seeded trip session")
        guard connected else { return }

        let resident = gateway.chat(for: key)
        await resident.load()
        var residentPages = 0
        while resident.hasMoreHistory && residentPages < 4 {
            #expect(await resident.loadOlder())
            residentPages += 1
        }
        #expect(resident.items.count == 302 && !resident.hasMoreHistory,
                "the registered chat is warm with the complete seeded history")
        let residentIDs = resident.items.map(\.id)

        let probe = ChatStore(sessionKey: key, agentId: "main", gateway: gateway, headless: true)
        probe.cacheRoot = nil
        #expect(probe !== resident && gateway.chat(for: key) === resident,
                "the paging store is independent and remains unregistered")
        #expect(probe.items.isEmpty && !probe.hasLoaded && probe.headless && probe.cacheRoot == nil,
                "the probe starts empty, unloaded, headless and uncached")

        await probe.load()
        #expect(probe.items.count == probe.historyLimit && probe.hasMoreHistory,
                "the probe loads only the newest history page")
        let newestPageIDs = probe.items.map(\.id)
        #expect(await probe.loadOlder())
        #expect(probe.items.count == 240 && Array(probe.items.suffix(newestPageIDs.count)).map(\.id) == newestPageIDs,
                "paging older history prepends a page without replacing the newest page")
        #expect(resident.items.count == 302 && resident.items.map(\.id) == residentIDs,
                "the warm registered transcript remains unchanged")
    }
}
