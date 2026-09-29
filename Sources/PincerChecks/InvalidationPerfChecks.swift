import Foundation
import Observation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

/// Observation invalidations while streaming, and the cost of one sessions row update at 300 sessions.
/// Prints numbers that are comparable before and after the #201 changes.
@MainActor
func runInvalidationPerfChecks() {
    #if DEBUG
    let key = "agent:main:dashboard:s0"
    let rowCount = 300
    func snapshot(bump: Int) -> JSONValue {
        let rows = (0..<rowCount).map { i in
            #"{"key":"agent:main:dashboard:s\#(i)","label":"Chat \#(i)","updatedAt":\#(1000 + i + (i == 1 ? bump : 0)),"lastMessagePreview":"m\#(i == 1 ? bump : 0)"}"#
        }
        return json(#"{"sessions":[\#(rows.joined(separator: ","))]}"#)
    }
    let gateway = GatewayStore(profile: GatewayProfile(name: "Perf", url: "ws://127.0.0.1:1", authMode: .none))
    gateway.applySnapshot(snapshot(bump: 0))
    let chat = gateway.chat(for: key)

    // Invalidations per token for what ChatView's body reads.
    let deltas = 200
    var running = 0, row = 0, sessions = 0
    func track(_ read: @escaping @MainActor () -> Void, _ count: @escaping @MainActor () -> Void) {
        withObservationTracking { read() } onChange: { MainActor.assumeIsolated { count() } }
    }
    for i in 0..<deltas {
        // Re-arm before every delta, as SwiftUI does after each body evaluation.
        track({ _ = chat.isRunning }, { running += 1 })
        track({ _ = gateway.sessions[key] }, { sessions += 1 })
        track({ _ = chat.sessionRow }, { row += 1 })
        chat.handleChat(["runId": "r1", "sessionKey": .string(key), "state": "delta", "deltaText": .string("tok\(i) ")])
    }
    // The first delta legitimately starts the run.
    let perTokenRunning = Double(running) / Double(deltas)
    let perTokenRow = Double(row) / Double(deltas)
    let perTokenSessions = Double(sessions) / Double(deltas)
    print(String(format: "  invalidations/token  isRunning=%.3f  sessionRow=%.3f  gateway.sessions[key]=%.3f  (over %d deltas)",
                 perTokenRunning, perTokenRow, perTokenSessions, deltas))
    check(running <= 2, "isRunning invalidates only on run start (\(running))")
    check(row == 0, "sessionRow does not invalidate while streaming (\(row))")

    // Cost of one sessions.changed-style update, including the sidebar's sections().
    let rounds = 50
    let start = ContinuousClock.now
    for n in 1...rounds {
        gateway.applySnapshot(snapshot(bump: n))
        _ = gateway.sections()
    }
    let msPerEvent = (ContinuousClock.now - start) / rounds
    let ms = Double(msPerEvent.components.seconds) * 1000 + Double(msPerEvent.components.attoseconds) / 1e15
    print(String(format: "  sessions update at %d sessions: %.3f ms/event (apply + sections, N=%d)", rowCount, ms, rounds))
    check(ms < 50, "sessions update stays under 50 ms at 300 sessions")

    // An identical snapshot must not invalidate observers of `sessions`.
    var identical = 0
    track({ _ = gateway.sessions }, { identical += 1 })
    gateway.applySnapshot(snapshot(bump: rounds))
    check(identical == 0, "identical sessions write does not invalidate")
    #else
    print("  skipped: needs @testable access to PincerKit (debug builds)")
    #endif
}
