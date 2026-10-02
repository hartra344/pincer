import Foundation

/// Bounded, body-free diagnostics for the one-time forwarded-sender cache repair.
/// The recorder and its storage are debug-only; release calls optimize to an inline no-op.
@MainActor
public enum ForwardedSenderRefreshDiagnostics {
    public enum Store: Sendable, Equatable {
        case open
        case headless
    }

    public enum Disposition: Sendable, Equatable {
        case more
        case complete
        case abort
    }

    public enum AbortReason: Sendable, Equatable {
        case cacheUnreadable
        case disconnected
        case gatewayChanged
        case connectionEpochChanged
        case cacheGenerationChanged
        case applicationInactive
        case cancelled
        case requestFailed
        case missingMessages
        case malformedPage
        case changedTwiceDuringReconcile
    }

    public enum Phase: Sendable, Equatable {
        case fillStarted(epoch: Int, generation: Int, cachedRows: Int)
        case request(offset: Int, limit: Int, scanned: Int)
        case page(offset: Int, limit: Int, messageCount: Int?, hasMore: Bool?, nextOffset: Int?, disposition: Disposition)
        case scanAborted(reason: AbortReason, offset: Int?, scanned: Int)
        case reconcileStarted(scanned: Int, revision: Int)
        case reconciled(scanned: Int, rowCount: Int, revision: Int)
        case snapshotWriteStarted(store: Store, pending: Bool, completed: Bool, revision: Int)
        case snapshotWriteFinished(store: Store, pending: Bool, completed: Bool,
                                   modifiedReported: Bool, unchangedReported: Bool)
        case snapshotStateAfterWrite(store: Store, pending: Bool, completed: Bool, revision: Int)
        case saveScheduled(store: Store, pending: Bool, completed: Bool, revision: Int, delayMilliseconds: Int)
        case adoptionRead(storePending: Bool, diskPending: Bool?, diskComplete: Bool?,
                          contextValid: Bool, cacheReadable: Bool)
    }

    public struct Event: Sendable, Equatable {
        public let ordinal: Int
        public let phase: Phase
    }

    private struct Key: Hashable {
        let gatewayID: UUID
        let sessionKey: String
    }

    private struct Trace {
        var nextOrdinal = 0
        var events: [Event] = []
    }

    // Hard count bounds retain at most eight chats and forty fixed-size events per chat. Session
    // keys are capped separately; the LRU cost uses key bytes plus event-count units, not heap bytes.
    private static let maxSessionKeyBytes = 512
    #if DEBUG
    private static var traces = BoundedLRUCache<Key, Trace>(countLimit: 8, costLimit: 8 * (512 + 40))
    #endif
    private static let eventsPerTrace = 40

    public static func events(gatewayID: UUID, sessionKey: String) -> [Event] {
        #if DEBUG
        guard sessionKey.utf8.count <= Self.maxSessionKeyBytes else { return [] }
        return self.traces.value(for: Key(gatewayID: gatewayID, sessionKey: sessionKey))?.events ?? []
        #else
        return []
        #endif
    }

    public static func reset(gatewayID: UUID, sessionKey: String) {
        #if DEBUG
        guard sessionKey.utf8.count <= Self.maxSessionKeyBytes else { return }
        let key = Key(gatewayID: gatewayID, sessionKey: sessionKey)
        _ = self.traces.insert(Trace(), for: key, cost: sessionKey.utf8.count)
        #else
        _ = gatewayID
        _ = sessionKey
        #endif
    }

    @inline(__always)
    static func record(gatewayID: UUID, sessionKey: String, phase: Phase) {
        #if DEBUG
        guard sessionKey.utf8.count <= Self.maxSessionKeyBytes else { return }
        let key = Key(gatewayID: gatewayID, sessionKey: sessionKey)
        var trace = self.traces.value(for: key) ?? Trace()
        let event = Event(ordinal: trace.nextOrdinal, phase: phase)
        trace.nextOrdinal += 1
        trace.events.append(event)
        if trace.events.count > Self.eventsPerTrace {
            trace.events.removeFirst(trace.events.count - Self.eventsPerTrace)
        }
        _ = self.traces.insert(trace, for: key, cost: sessionKey.utf8.count + trace.events.count)
        #else
        _ = gatewayID
        _ = sessionKey
        _ = phase
        #endif
    }
}
