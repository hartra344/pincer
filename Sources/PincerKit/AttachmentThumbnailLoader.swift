import CoreGraphics
import Foundation
import Observation

/// Bounded, shared decode work for small attachment previews.
@MainActor
@Observable
public final class AttachmentThumbnailLoader {
    public static let shared = AttachmentThumbnailLoader()
    nonisolated public static let byteBudget = 16 * 1024 * 1024
    nonisolated public static let maximumInputBytes = 32 * 1024 * 1024
    nonisolated public static let maximumPixelSize = 512
    static let maximumOwnersPerWork = 64

    /// Changes after a decode finishes so mounted views can retry requests rejected under pressure.
    public private(set) var revision: UInt64 = 0

    @ObservationIgnored private var cache: DecodedImageCache
    @ObservationIgnored private let decoder: @Sendable (Data, Int) -> CGImage?
    @ObservationIgnored private let pendingLimit: Int
    @ObservationIgnored private let pendingByteLimit: Int
    @ObservationIgnored private var pending: [Work] = []
    @ObservationIgnored private var pendingBytes = 0
    @ObservationIgnored private var active: Work?
    @ObservationIgnored private var failedKeys: [Key] = []
    #if DEBUG
    @ObservationIgnored public var debugDecodeObserver: (@Sendable (UUID, UUID, String, Int, Bool, CGImage?) -> Void)?
    #endif

    public struct Key: Hashable, Sendable {
        public let previewIdentity: UUID
        public let maxPixel: Int

        public init(previewIdentity: UUID, maxPixel: Int) {
            self.previewIdentity = previewIdentity
            self.maxPixel = maxPixel
        }

        var cacheKey: String { "\(self.previewIdentity.uuidString):\(self.maxPixel)" }
    }

    private struct Work {
        let key: Key
        let attachmentID: UUID
        let fileName: String
        let data: Data
        let token: UUID
        var owners: Set<UUID>
        var abandoned = false
    }

    /// Test seams use smaller limits and a controlled decoder; production uses `ImageCodec`.
    init(
        byteBudget: Int = AttachmentThumbnailLoader.byteBudget,
        pendingLimit: Int = 8,
        pendingByteLimit: Int = 16 * 1024 * 1024,
        decoder: @escaping @Sendable (Data, Int) -> CGImage? = { data, maxPixel in
            ImageCodec.decode(data, maxPixel: maxPixel)
        }
    ) {
        self.cache = DecodedImageCache(byteLimit: max(1, byteBudget))
        self.pendingLimit = max(0, pendingLimit)
        self.pendingByteLimit = max(0, pendingByteLimit)
        self.decoder = decoder
    }

    nonisolated public static func targetPixelSize(points: Double, displayScale: Double) -> Int {
        guard !points.isNaN, points > 0, displayScale.isFinite, displayScale > 0 else { return 1 }
        guard points.isFinite else { return Self.maximumPixelSize }
        let scaled = (points * displayScale).rounded(.up)
        guard scaled.isFinite else { return Self.maximumPixelSize }
        return min(Self.maximumPixelSize, max(1, Int(min(scaled, Double(Self.maximumPixelSize)))))
    }

    public func cached(_ attachment: OutgoingAttachment, maxPixel: Int) -> CGImage? {
        let key = Self.key(for: attachment, maxPixel: maxPixel)
        return self.cache.value(for: key.cacheKey)
    }

    /// Returns false when capacity is full. Such a request retains no attachment data and can
    /// retry after `revision` changes.
    @discardableResult
    public func request(_ attachment: OutgoingAttachment, maxPixel: Int, owner: UUID) -> Bool {
        let key = Self.key(for: attachment, maxPixel: maxPixel)
        if self.cache.value(for: key.cacheKey) != nil || self.failedKeys.contains(key) { return true }
        guard attachment.data.count <= Self.maximumInputBytes else {
            self.rememberFailure(key)
            return true
        }

        if var active = self.active, active.key == key {
            guard active.owners.contains(owner) || active.owners.count < Self.maximumOwnersPerWork else { return false }
            active.owners.insert(owner)
            active.abandoned = false
            self.active = active
            return true
        }
        if let index = self.pending.firstIndex(where: { $0.key == key }) {
            guard self.pending[index].owners.contains(owner)
                    || self.pending[index].owners.count < Self.maximumOwnersPerWork else { return false }
            self.pending[index].owners.insert(owner)
            return true
        }

        let work = Work(key: key, attachmentID: attachment.id, fileName: attachment.fileName,
                        data: attachment.data, token: UUID(), owners: [owner])
        guard self.active != nil else {
            self.start(work)
            return true
        }
        guard self.pending.count < self.pendingLimit,
              attachment.data.count <= self.pendingByteLimit - self.pendingBytes else { return false }
        self.pending.append(work)
        self.pendingBytes += work.data.count
        return true
    }

    public func release(_ attachment: OutgoingAttachment, maxPixel: Int, owner: UUID) {
        self.release(Self.key(for: attachment, maxPixel: maxPixel), owner: owner)
    }

    public func release(_ key: Key, owner: UUID) {
        if var active = self.active, active.key == key {
            active.owners.remove(owner)
            active.abandoned = active.owners.isEmpty
            self.active = active
        }
        guard let index = self.pending.firstIndex(where: { $0.key == key }) else { return }
        self.pending[index].owners.remove(owner)
        if self.pending[index].owners.isEmpty {
            self.pendingBytes -= self.pending[index].data.count
            self.pending.remove(at: index)
        }
    }

    var decodedBytes: Int { self.cache.totalBytes }
    var cachedImageCount: Int { self.cache.count }
    var activeDecodeCount: Int { self.active == nil ? 0 : 1 }
    var pendingDecodeCount: Int { self.pending.count }
    var pendingDataBytes: Int { self.pendingBytes }

    private static func key(for attachment: OutgoingAttachment, maxPixel: Int) -> Key {
        Key(previewIdentity: attachment.previewIdentity,
            maxPixel: min(Self.maximumPixelSize, max(1, maxPixel)))
    }

    private func start(_ work: Work) {
        self.active = work
        let decoder = self.decoder
        #if DEBUG
        let observer = self.debugDecodeObserver
        #endif
        Task { [weak self, work] in
            let image = await Task.detached(priority: .utility) {
                #if DEBUG
                Self.decode(work.data, maxPixel: work.key.maxPixel, attachmentID: work.attachmentID,
                            previewIdentity: work.key.previewIdentity, fileName: work.fileName,
                            decoder: decoder, observer: observer)
                #else
                Self.decode(work.data, maxPixel: work.key.maxPixel, decoder: decoder)
                #endif
            }.value
            self?.finish(work, image: image)
        }
    }

    #if DEBUG
    private nonisolated static func decode(
        _ data: Data,
        maxPixel: Int,
        attachmentID: UUID,
        previewIdentity: UUID,
        fileName: String,
        decoder: @Sendable (Data, Int) -> CGImage?,
        observer: (@Sendable (UUID, UUID, String, Int, Bool, CGImage?) -> Void)?
    ) -> CGImage? {
        let image = decoder(data, maxPixel)
        observer?(attachmentID, previewIdentity, fileName, maxPixel, Thread.isMainThread, image)
        return image
    }
    #else
    private nonisolated static func decode(_ data: Data, maxPixel: Int, decoder: @Sendable (Data, Int) -> CGImage?) -> CGImage? {
        decoder(data, maxPixel)
    }
    #endif

    private func finish(_ work: Work, image: CGImage?) {
        guard let active = self.active, active.token == work.token else { return }
        self.active = nil
        if let image, !active.abandoned, !active.owners.isEmpty {
            _ = self.cache.insert(image, for: active.key.cacheKey)
        } else if image == nil {
            self.rememberFailure(active.key)
        }
        self.revision &+= 1
        self.startNextIfPossible()
    }

    private func rememberFailure(_ key: Key) {
        self.failedKeys.removeAll { $0 == key }
        self.failedKeys.append(key)
        if self.failedKeys.count > 64 { self.failedKeys.removeFirst(self.failedKeys.count - 64) }
    }

    private func startNextIfPossible() {
        guard self.active == nil else { return }
        while !self.pending.isEmpty {
            let next = self.pending.removeFirst()
            self.pendingBytes -= next.data.count
            guard !next.owners.isEmpty else { continue }
            self.start(next)
            return
        }
    }
}
