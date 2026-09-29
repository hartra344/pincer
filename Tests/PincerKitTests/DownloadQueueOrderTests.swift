import Testing
@testable import PincerKit

@MainActor
@Suite("Download queue order")
struct DownloadQueueOrderTests {
    @Test func newestWaiterRunsFirst() async {
        let limiter = DownloadLimiter(limit: 1)
        try? await limiter.acquire()
        var order: [Int] = []
        let tasks = (0..<4).map { i in
            Task { @MainActor in
                try? await limiter.acquire()
                order.append(i)
                limiter.release()
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        limiter.release()
        for task in tasks { await task.value }
        #expect(order == [3, 2, 1, 0])
    }

    @Test func explicitCapIsLargerThanTheInlineCap() {
        #expect(GatewayMediaClient.explicitMaxBytes == 200 * 1024 * 1024)
        #expect(GatewayMediaClient.explicitMaxBytes > GatewayMediaClient.defaultMaxBytes)
    }
}
