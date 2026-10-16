import Testing
@testable import PincerKit

@Suite("Talk hidden paging")
struct TalkHiddenPagingTests {
    @Test func fullRawPageMostlyHiddenKeepsPaging() {
        let r = ChatStore.olderPageContinuation(rawCount: 50, filteredCount: 3, hasMore: nil, offset: 100, limit: 50)
        #expect(r.hasMore)
        #expect(r.nextOffset == 150)
    }

    @Test func allHiddenPageKeepsPaging() {
        let r = ChatStore.olderPageContinuation(rawCount: 50, filteredCount: 0, hasMore: nil, offset: 0, limit: 50)
        #expect(r.hasMore)
        #expect(r.nextOffset == 50)
    }

    @Test func emptyRawPageStops() {
        let r = ChatStore.olderPageContinuation(rawCount: 0, filteredCount: 0, hasMore: nil, offset: 40, limit: 50)
        #expect(!r.hasMore)
        #expect(r.nextOffset == 40)
        #expect(!ChatStore.olderPageContinuation(rawCount: 0, filteredCount: 0, hasMore: true, offset: 0, limit: 50).hasMore)
    }

    @Test func explicitHasMoreWins() {
        #expect(!ChatStore.olderPageContinuation(rawCount: 50, filteredCount: 50, hasMore: false, offset: 0, limit: 50).hasMore)
        #expect(ChatStore.olderPageContinuation(rawCount: 5, filteredCount: 0, hasMore: true, offset: 0, limit: 50).hasMore)
    }
}
