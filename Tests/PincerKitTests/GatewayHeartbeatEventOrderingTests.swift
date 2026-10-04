import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Gateway heartbeat event ordering")
struct GatewayHeartbeatEventOrderingTests {
    private static func heartbeat(failed: Bool, timestamp: Int) -> JSONValue {
        ["ts": .number(Double(timestamp)), "status": .string(failed ? "failed" : "ok-token"),
         "reason": .string(failed ? "new heartbeat failure" : "new heartbeat success")]
    }

    @MainActor
    private final class Requests {
        let oldHeartbeat: JSONValue
        let health: JSONValue = ["ok": true, "ts": 1700000000000, "heartbeatSeconds": 0,
                                 "channels": ["telegram": ["accountId": "default", "enabled": true,
                                                             "configured": true, "running": true, "connected": false]]]
        var heartbeatError: GatewayError?
        var entered: Set<String> = []
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        private var released = false

        init(failed: Bool) {
            self.oldHeartbeat = GatewayHeartbeatEventOrderingTests.heartbeat(failed: failed, timestamp: 1700000000000)
        }

        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            guard method == "health" || method == "last-heartbeat" else {
                Issue.record("Unexpected actual refresh RPC: \(method)")
                return .null
            }
            // These responses represent snapshots computed before the intervening event.
            let response = method == "health" ? self.health : self.oldHeartbeat
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
            if method == "last-heartbeat", let error = self.heartbeatError { throw error }
            return response
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
    func newerHeartbeatEventSurvivesOlderRefresh(_ eventFailed: Bool) async throws {
        let requests = Requests(failed: !eventFailed)
        let model = GatewayHealthModel { method, params in try await requests.request(method, params) }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); requests.release() }
        try await requests.waitUntilBothEntered()
        let event = Self.heartbeat(failed: eventFailed, timestamp: 1700000001000)
        model.handle(event: "heartbeat", payload: event)
        let expected = try #require(GatewayHeartbeat(event))
        try #require(model.heartbeat == expected && model.heartbeatLoaded)
        try #require(model.activeIssues.contains { $0.id == "heartbeat:failed" } == eventFailed)
        requests.release()
        await refresh.value
        #expect(model.heartbeat?.at == expected.at)
        #expect(model.heartbeat?.status == expected.status)
        #expect(model.heartbeat?.reason == expected.reason)
        #expect(model.activeIssues.contains { $0.id == "heartbeat:failed" } == eventFailed)
        // A heartbeat event must not invalidate the independent health request.
        #expect(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000000))
        #expect(model.activeIssues.contains { $0.id == "channel:telegram:default" })
    }

    @Test(.timeLimit(.minutes(2)))
    func newerHeartbeatEventSurvivesOlderMissingMethodError() async throws {
        let requests = Requests(failed: false)
        requests.heartbeatError = .rpc(code: "INVALID_REQUEST", message: "unknown method: last-heartbeat", details: nil)
        let model = GatewayHealthModel { method, params in try await requests.request(method, params) }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); requests.release() }
        try await requests.waitUntilBothEntered()
        let event = Self.heartbeat(failed: true, timestamp: 1700000001000)
        model.handle(event: "heartbeat", payload: event)
        try #require(model.heartbeat == GatewayHeartbeat(event) && model.isAvailable(.heartbeat))
        requests.release()
        await refresh.value
        #expect(model.isAvailable(.heartbeat))
        #expect(model.heartbeat == GatewayHeartbeat(event))
        #expect(model.activeIssues.contains { $0.id == "heartbeat:failed" })
        #expect(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000000))
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func validRefreshPublishesWithoutANewerAcceptedEvent(_ malformedEvent: Bool) async throws {
        let requests = Requests(failed: true)
        let model = GatewayHealthModel { method, params in try await requests.request(method, params) }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); requests.release() }
        try await requests.waitUntilBothEntered()
        if malformedEvent { model.handle(event: "heartbeat", payload: .array([])) }
        try #require(model.heartbeat == nil && !model.heartbeatLoaded)
        requests.release()
        await refresh.value
        #expect(model.heartbeat == GatewayHeartbeat(requests.oldHeartbeat) && model.heartbeatLoaded)
        #expect(model.activeIssues.map(\.id) == ["channel:telegram:default", "heartbeat:failed"])
        #expect(model.isAvailable(.heartbeat))
        #expect(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000000))
    }
}
