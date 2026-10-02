import Foundation
import Testing
@testable import PincerKit

#if DEBUG
@Suite("Forwarded sender refresh diagnostics")
@MainActor
struct ForwardedSenderRefreshDiagnosticsTests {
    @Test func traceRetainsOnlyTheMostRecentFortyEventsAndResetClearsIt() {
        let gatewayID = UUID()
        let sessionKey = "agent:diagnostics:bounded-test"
        ForwardedSenderRefreshDiagnostics.reset(gatewayID: gatewayID, sessionKey: sessionKey)

        for scanned in 0..<50 {
            ForwardedSenderRefreshDiagnostics.record(
                gatewayID: gatewayID, sessionKey: sessionKey,
                phase: .request(offset: scanned, limit: 120, scanned: scanned))
        }

        let events = ForwardedSenderRefreshDiagnostics.events(gatewayID: gatewayID, sessionKey: sessionKey)
        #expect(events.count == 40)
        #expect(events.map(\.ordinal) == Array(10..<50))
        #expect(events.allSatisfy {
            if case .request = $0.phase { true } else { false }
        })

        ForwardedSenderRefreshDiagnostics.reset(gatewayID: gatewayID, sessionKey: sessionKey)
        #expect(ForwardedSenderRefreshDiagnostics.events(gatewayID: gatewayID, sessionKey: sessionKey).isEmpty)
    }

    @Test func traceStorageIsBoundedAcrossChatScopes() {
        let gatewayID = UUID()
        let sessionKeys = (0..<9).map { "agent:diagnostics:scope-\($0)" }
        for sessionKey in sessionKeys {
            ForwardedSenderRefreshDiagnostics.reset(gatewayID: gatewayID, sessionKey: sessionKey)
            ForwardedSenderRefreshDiagnostics.record(
                gatewayID: gatewayID, sessionKey: sessionKey,
                phase: .request(offset: 0, limit: 120, scanned: 0))
        }

        #expect(ForwardedSenderRefreshDiagnostics.events(gatewayID: gatewayID, sessionKey: sessionKeys[0]).isEmpty)
        #expect(ForwardedSenderRefreshDiagnostics.events(gatewayID: gatewayID, sessionKey: sessionKeys[8]).count == 1)
    }

    @Test func oversizedSessionKeyDoesNotDisplaceBoundedTrace() {
        let gatewayID = UUID()
        let sessionKey = "agent:diagnostics:kept"
        ForwardedSenderRefreshDiagnostics.reset(gatewayID: gatewayID, sessionKey: sessionKey)
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .request(offset: 0, limit: 120, scanned: 0))

        let oversizedKey = String(repeating: "x", count: 513)
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: oversizedKey,
            phase: .fillStarted(epoch: 1, generation: 1, cachedRows: 0))

        #expect(ForwardedSenderRefreshDiagnostics.events(gatewayID: gatewayID, sessionKey: oversizedKey).isEmpty)
        let retained = ForwardedSenderRefreshDiagnostics.events(gatewayID: gatewayID, sessionKey: sessionKey)
        #expect(retained.count == 1)
        #expect(retained.first?.phase == .request(offset: 0, limit: 120, scanned: 0))
    }

    @Test func traceDistinguishesAbortReconcileAndSnapshotWriteOutcomes() {
        let gatewayID = UUID()
        let sessionKey = "agent:diagnostics:lifecycle-test"
        ForwardedSenderRefreshDiagnostics.reset(gatewayID: gatewayID, sessionKey: sessionKey)
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .page(offset: 120, limit: 120, messageCount: nil, hasMore: nil, nextOffset: nil,
                         disposition: .abort))
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .scanAborted(reason: .missingMessages, offset: 120, scanned: 120))
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .snapshotWriteStarted(store: .headless, pending: true, completed: false, revision: 7))
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .snapshotWriteFinished(store: .headless, pending: true, completed: false,
                                          modifiedReported: false, unchangedReported: false))
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .page(offset: 240, limit: 60, messageCount: 42, hasMore: false,
                         nextOffset: nil, disposition: .complete))
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .reconciled(scanned: 240, rowCount: 300, revision: 8))
        ForwardedSenderRefreshDiagnostics.record(
            gatewayID: gatewayID, sessionKey: sessionKey,
            phase: .snapshotWriteFinished(store: .headless, pending: false, completed: true,
                                          modifiedReported: false, unchangedReported: true))

        let phases = ForwardedSenderRefreshDiagnostics.events(gatewayID: gatewayID, sessionKey: sessionKey).map(\.phase)
        #expect(phases == [
            .page(offset: 120, limit: 120, messageCount: nil, hasMore: nil, nextOffset: nil,
                  disposition: .abort),
            .scanAborted(reason: .missingMessages, offset: 120, scanned: 120),
            .snapshotWriteStarted(store: .headless, pending: true, completed: false, revision: 7),
            .snapshotWriteFinished(store: .headless, pending: true, completed: false,
                                   modifiedReported: false, unchangedReported: false),
            .page(offset: 240, limit: 60, messageCount: 42, hasMore: false,
                  nextOffset: nil, disposition: .complete),
            .reconciled(scanned: 240, rowCount: 300, revision: 8),
            .snapshotWriteFinished(store: .headless, pending: false, completed: true,
                                   modifiedReported: false, unchangedReported: true),
        ])
    }
}
#endif
