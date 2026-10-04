import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Gateway health event ordering")
struct GatewayHealthEventOrderingTests {
    private static func health(connected: Bool, timestamp: Int) -> JSONValue {
        ["ok": true, "ts": .number(Double(timestamp)), "durationMs": 1,
         "heartbeatSeconds": 0,
         "channelOrder": ["telegram"], "channelLabels": ["telegram": "Telegram"],
         "channels": ["telegram": ["accountId": "default", "enabled": true,
                                     "configured": true, "running": true,
                                     "connected": .bool(connected)]]]
    }

    @MainActor
    private final class Requests {
        let oldHealth: JSONValue
        let beat: JSONValue = ["ts": 1700000000000, "status": "failed", "reason": "held heartbeat"]
        var healthError: GatewayError?
        var entered: Set<String> = []
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        private var released = false

        init(connected: Bool) { self.oldHealth = GatewayHealthEventOrderingTests.health(connected: connected, timestamp: 1700000000000) }

        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            guard method == "health" || method == "last-heartbeat" else {
                Issue.record("Unexpected actual RPC: \(method)")
                return .null
            }
            self.entered.insert(method)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if self.released || Task.isCancelled { continuation.resume() }
                    else { self.waiters[method] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.release() }
            }
            try Task.checkCancellation()
            if method == "health", let error = self.healthError { throw error }
            return method == "health" ? self.oldHealth : self.beat
        }

        func waitUntilBothEntered() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            while self.entered != Set(["health", "last-heartbeat"]) {
                try Task.checkCancellation()
                if clock.now >= deadline {
                    Issue.record("Actual refresh did not reach both held RPCs")
                    throw CancellationError()
                }
                await Task.yield()
            }
        }

        func release() {
            self.released = true
            let waiters = self.waiters.values
            self.waiters = [:]
            for waiter in waiters { waiter.resume() }
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func newerHealthEventSurvivesOlderRefresh(_ eventConnected: Bool) async throws {
        let requests = Requests(connected: !eventConnected)
        let model = GatewayHealthModel { method, params in try await requests.request(method, params) }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); requests.release() }
        try await requests.waitUntilBothEntered()
        model.handle(event: "health", payload: Self.health(connected: eventConnected, timestamp: 1700000001000))
        try #require(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000001))
        try #require(model.health?.channels.first?.summary.connected == eventConnected)
        let expectedChannelIssues = eventConnected ? [] : ["channel:telegram:default"]
        try #require(model.activeIssues.filter { $0.kind == .channel }.map(\.id) == expectedChannelIssues)
        requests.release()
        await refresh.value
        #expect(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000001))
        #expect(model.health?.channels.first?.summary.connected == eventConnected)
        #expect(model.activeIssues.filter { $0.kind == .channel }.map(\.id) == expectedChannelIssues)
        // A health event must not discard the independently requested heartbeat domain.
        #expect(model.heartbeatLoaded)
        #expect(model.heartbeat?.reason == "held heartbeat")
        #expect(model.activeIssues.contains { $0.id == "heartbeat:failed" })
    }

    @Test(.timeLimit(.minutes(2)))
    func refreshWithoutInterveningEventPublishesBothActualResults() async throws {
        let requests = Requests(connected: false)
        let model = GatewayHealthModel { method, params in try await requests.request(method, params) }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); requests.release() }
        try await requests.waitUntilBothEntered()
        try #require(model.health == nil && !model.heartbeatLoaded)
        requests.release()
        await refresh.value
        #expect(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000000))
        #expect(model.health?.channels.first?.summary.connected == false)
        #expect(model.activeIssues.map(\.id) == ["channel:telegram:default", "heartbeat:failed"])
        #expect(model.heartbeat?.reason == "held heartbeat")
    }
    @Test(.timeLimit(.minutes(2)), arguments: ["UNAVAILABLE", "INVALID_REQUEST", "FAILED"])
    func newerHealthEventSurvivesOlderRequestError(_ code: String) async throws {
        let requests = Requests(connected: false)
        requests.healthError = .rpc(code: code,
                                   message: code == "INVALID_REQUEST" ? "unknown method: health" : "held health failure",
                                   details: nil)
        let model = GatewayHealthModel { method, params in try await requests.request(method, params) }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); requests.release() }
        try await requests.waitUntilBothEntered()
        model.handle(event: "health", payload: Self.health(connected: true, timestamp: 1700000001000))
        try #require(model.health?.channels.first?.summary.connected == true)
        try #require(model.healthFailure == nil && model.isAvailable(.health) && model.loadState == .idle)
        requests.release()
        await refresh.value
        #expect(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000001))
        #expect(model.healthFailure == nil)
        #expect(model.isAvailable(.health))
        #expect(model.loadState == .idle)
        #expect(model.activeIssues.filter { $0.kind == .channel }.isEmpty)
        #expect(model.heartbeatLoaded && model.heartbeat?.reason == "held heartbeat")
    }

    @Test(.timeLimit(.minutes(2)))
    func ignoredMalformedHealthEventDoesNotInvalidatePendingHealthResult() async throws {
        let requests = Requests(connected: false)
        let model = GatewayHealthModel { method, params in try await requests.request(method, params) }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); requests.release() }
        try await requests.waitUntilBothEntered()
        model.handle(event: "health", payload: .array([]))
        try #require(model.health == nil)
        requests.release()
        await refresh.value
        #expect(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000000))
        #expect(model.health?.channels.first?.summary.connected == false)
        #expect(model.activeIssues.map(\.id) == ["channel:telegram:default", "heartbeat:failed"])
    }

}
