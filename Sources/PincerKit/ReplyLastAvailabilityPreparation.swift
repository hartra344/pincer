import Foundation
import Observation

/// Global bounded exact availability preparation. Pending requests retain only weak stores and cursors.
@MainActor @Observable
package final class ReplyLastAvailabilityPreparation {
    package static let shared = ReplyLastAvailabilityPreparation()
    package static let pendingLimit = 32
    package static let chunkUnitLimit = 2048
    package static let inputByteLimit = 8192
    package private(set) var admissionRevision = 0
    @ObservationIgnored private var pending: [Request] = []
    @ObservationIgnored private var active: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var drainWaiters: [UUID: (CheckedContinuation<Void, Never>, Task<Void, Never>)] = [:]
    #if DEBUG
    @ObservationIgnored package var chunkGate: (@Sendable () async -> Void)?
    package private(set) var peakChunkBytes = 0
    #endif
    package var pendingCount: Int { self.pending.count }
    package var activeCount: Int { self.active == nil ? 0 : 1 }

    @MainActor private final class Request: Sendable {
        weak var store: ChatStore?
        let identity: ObjectIdentifier
        let revision: Int
        let generation: Int
        var itemIndex: Int
        var blockIndex = 0
        var cursor: String.Index?
        var canceled = false
        init(_ store: ChatStore) {
            self.store = store
            self.identity = ObjectIdentifier(store)
            self.revision = store.contentRevision
            self.generation = store.replyLastSourceGeneration
            self.itemIndex = store.items.count - 1
        }
    }
    private struct Chunk: Sendable {
        var units: [UInt16] = []
        var blockEnded = false
        var itemEnded = false
        var id: String?
        var finished = false
        var stale = false
        var unsupported = false
    }
    package func request(_ store: ChatStore) {
        guard !store.cachingStopped, store.replyLastPreparedRevision != store.contentRevision, store.replyLastUnsupportedGeneration != store.replyLastSourceGeneration else { return }
        let identity = ObjectIdentifier(store)
        if let active, active.identity == identity && active.revision == store.contentRevision && active.generation == store.replyLastSourceGeneration && !active.canceled { return }
        if self.pending.contains(where: { $0.identity == identity && $0.revision == store.contentRevision && $0.generation == store.replyLastSourceGeneration }) { return }
        self.pending.removeAll { $0.store == nil || $0.canceled || $0.identity == identity }
        guard self.active == nil || self.pending.count < Self.pendingLimit else { return }
        let request = Request(store)
        if self.active == nil { self.start(request) } else { self.pending.append(request) }
    }
    package func cancel(_ store: ChatStore) {
        let identity = ObjectIdentifier(store)
        if self.active?.identity == identity { self.active?.canceled = true }
        self.pending.removeAll { $0.store == nil || $0.identity == identity }
    }
    package func invalidate(_ store: ChatStore) { self.cancel(store); self.request(store) }
    private func extract(_ request: Request) -> Chunk {
        guard !request.canceled, let store = request.store, store.contentRevision == request.revision, store.replyLastSourceGeneration == request.generation else { return Chunk(stale: true) }
        var chunk = Chunk()
        var visits = 0
        while visits < 64 {
            guard request.itemIndex >= 0 else { chunk.finished = true; return chunk }
            guard request.itemIndex < store.items.count else { return Chunk(stale: true) }
            let item = store.items[request.itemIndex]
            visits += 1
            guard item.isReplyable else {
                request.itemIndex -= 1; request.blockIndex = 0; request.cursor = nil
                continue
            }
            guard let id = ChatStore.boundedReplyLastID(item.transcriptId) else { return Chunk(unsupported: true) }
            chunk.id = id
            if item.role == .user { chunk.finished = true; return chunk }
            guard request.blockIndex < item.blocks.count else {
                request.itemIndex -= 1; request.blockIndex = 0; request.cursor = nil
                chunk.itemEnded = true
                return chunk
            }
            guard visits < 64 else { return chunk }
            visits += 1
            guard case let .text(text) = item.blocks[request.blockIndex] else {
                request.blockIndex += 1; request.cursor = nil
                continue
            }
            // View and source stay scoped to this synchronous extraction, never crossing await.
            let view = text.utf16
            var cursor = request.cursor ?? view.startIndex
            let end = view.endIndex
            chunk.units.reserveCapacity(Self.chunkUnitLimit)
            while cursor != end && chunk.units.count < Self.chunkUnitLimit {
                chunk.units.append(view[cursor])
                cursor = view.index(after: cursor)
            }
            guard chunk.units.capacity * MemoryLayout<UInt16>.stride <= Self.inputByteLimit else { return Chunk(unsupported: true) }
            #if DEBUG
            self.peakChunkBytes = max(self.peakChunkBytes, chunk.units.capacity * MemoryLayout<UInt16>.stride)
            #endif
            if cursor == end {
                request.blockIndex += 1; request.cursor = nil; chunk.blockEnded = true
            } else { request.cursor = cursor }
            return chunk
        }
        return chunk
    }
    private func start(_ request: Request) {
        self.active = request
        #if DEBUG
        let gate = self.chunkGate
        #else
        let gate: (@Sendable () async -> Void)? = nil
        #endif
        self.worker = Task.detached(priority: .utility) { [weak self] in
            var high: UInt16?
            var result: String?
            var valid = true
            var unsupported = false
            while !Task.isCancelled {
                guard let chunk = await self?.extract(request) else { valid = false; break }
                if chunk.stale { valid = false; break }
                if chunk.unsupported { unsupported = true; break }
                if chunk.finished { result = chunk.id; break }
                if let gate { await gate() }
                if Task.isCancelled { valid = false; break }
                #if DEBUG
                if !chunk.units.isEmpty, let id = chunk.id { ReplyLastAvailabilityDebugProbe.record(tracking: id) }
                #endif
                var found = false
                for unit in chunk.units {
                    if let leading = high {
                        high = nil
                        if (0xDC00...0xDFFF).contains(unit) {
                            let value = 0x10000 + (UInt32(leading - 0xD800) << 10) + UInt32(unit - 0xDC00)
                            if !CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(value)!) { found = true; break }
                            continue
                        }
                        // Error correction produces U+FFFD, which is not whitespace.
                        found = true; break
                    }
                    if (0xD800...0xDBFF).contains(unit) { high = unit; continue }
                    let value = (0xDC00...0xDFFF).contains(unit) ? 0xFFFD : UInt32(unit)
                    if !CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(value)!) { found = true; break }
                }
                if (chunk.blockEnded || chunk.itemEnded) && high != nil { found = true; high = nil }
                if found { result = chunk.id; break }
                await Task.yield()
            }
            if Task.isCancelled { valid = false }
            await self?.finish(request, result: result, valid: valid, unsupported: unsupported)
        }
    }
    private func finish(_ request: Request, result: String?, valid: Bool, unsupported: Bool) {
        guard self.active === request else { return }
        if valid, !request.canceled, let store = request.store, store.contentRevision == request.revision, store.replyLastSourceGeneration == request.generation {
            if unsupported { store.replyLastUnsupportedGeneration = request.generation }
            else {
                store.replyLastPreparedRevision = request.revision
                store.replyLastPreparedID = result
            }
            store.replyLastReadyRevision &+= 1
        }
        self.active = nil; self.worker = nil
        self.admissionRevision &+= 1
        while !self.pending.isEmpty {
            let next = self.pending.removeFirst()
            guard !next.canceled, let store = next.store, store.contentRevision == next.revision, store.replyLastSourceGeneration == next.generation else { continue }
            self.start(next); break
        }
        if self.active == nil {
            let waiters = self.drainWaiters
            self.drainWaiters.removeAll()
            for (_, waiter) in waiters { waiter.1.cancel(); waiter.0.resume() }
        }
    }
    package func waitUntilIdle(timeout: Duration = .seconds(30)) async {
        guard self.active != nil, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.active != nil, !Task.isCancelled, self.drainWaiters.count < 32 else { continuation.resume(); return }
                let fence = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { self?.finishDrain(id) }
                }
                self.drainWaiters[id] = (continuation, fence)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finishDrain(id) } }
    }
    private func finishDrain(_ id: UUID) {
        guard let waiter = self.drainWaiters.removeValue(forKey: id) else { return }
        waiter.1.cancel(); waiter.0.resume()
    }
    package var drainWaiterCount: Int { self.drainWaiters.count }
}

extension ChatStore {
    static func boundedReplyLastID(_ id: String?) -> String? {
        guard let id, id.isContiguousUTF8,
              let bytes = id.utf8.withContiguousStorageIfAvailable({ $0.count }), bytes <= 256 else { return nil }
        return id
    }
    func cancelReplyLastAvailability() {
        self.replyLastSourceGeneration &+= 1
        self.replyLastPreparedRevision = nil
        self.replyLastPreparedID = nil
        self.replyLastUnsupportedGeneration = nil
        self.replyLastReadyRevision &+= 1
        self.replyLastPreparation.cancel(self)
    }
    func invalidateReplyLastAvailability() {
        if self.replyLastPreparedRevision != self.contentRevision {
            self.replyLastPreparedRevision = nil
            self.replyLastPreparedID = nil
        }
        self.replyLastUnsupportedGeneration = nil
        self.replyLastReadyRevision &+= 1
        self.replyLastPreparation.invalidate(self)
    }
}
