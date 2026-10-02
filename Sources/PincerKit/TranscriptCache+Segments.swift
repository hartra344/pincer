import Foundation
import Synchronization

/// v8 storage: `<digest>.json` is a small manifest naming segment files in `<digest>.segments/`.
extension TranscriptCache {
    struct VersionPeek: Decodable {
        let version: Int
    }

    struct SegmentRef: Codable, Equatable {
        var file: String
        var count: Int
        var firstId: String
        var lastId: String
    }

    struct Manifest: Codable {
        var version: Int
        var complete: Bool
        var activityMs: Double?
        var retained: Bool
        var forwardedSenderRefreshPending: Bool
        /// Identifies this write; the search index uses it to know which save it last saw.
        var token: String
        var segments: [SegmentRef]

        private enum CodingKeys: String, CodingKey {
            case version, complete, activityMs, retained, forwardedSenderRefreshPending, token, segments
        }

        init(version: Int, complete: Bool, activityMs: Double?, retained: Bool, forwardedSenderRefreshPending: Bool,
             token: String, segments: [SegmentRef])
        {
            self.version = version
            self.complete = complete
            self.activityMs = activityMs
            self.retained = retained
            self.forwardedSenderRefreshPending = forwardedSenderRefreshPending
            self.token = token
            self.segments = segments
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try c.decode(Int.self, forKey: .version)
            self.complete = try c.decode(Bool.self, forKey: .complete)
            self.activityMs = try c.decodeIfPresent(Double.self, forKey: .activityMs)
            self.retained = try c.decodeIfPresent(Bool.self, forKey: .retained) ?? false
            self.forwardedSenderRefreshPending = try c.decodeIfPresent(Bool.self, forKey: .forwardedSenderRefreshPending)
                ?? (self.version < Snapshot.currentVersion)
            self.token = try c.decode(String.self, forKey: .token)
            self.segments = try c.decode([SegmentRef].self, forKey: .segments)
        }
    }

    /// What one save wrote.
    public struct SaveResult: Sendable {
        public var bytesWritten = 0
        public var filesWritten = 0
        /// Nothing changed since the last write, so nothing was written.
        public var unchanged = false
        /// The manifest's modification date after a write; nil when nothing was written or it failed.
        var modified: Date?
        /// How this write relates to the previous one, for the search index.
        var change: IndexChange?
        /// A save that kept older items: the segments before the ones rewritten, whose items the
        /// index needs to see ahead of the window, and the older items of the boundary segment.
        var older: [SegmentRef]?
        var boundaryKept: [ChatItem] = []
        /// The manifest's `complete` for a save that kept older items.
        var complete: Bool?

        public init(bytesWritten: Int = 0, filesWritten: Int = 0, unchanged: Bool = false) {
            self.bytesWritten = bytesWritten
            self.filesWritten = filesWritten
            self.unchanged = unchanged
        }
    }

    /// A segment as last written: in-memory only, so fingerprints are seeded per process.
    struct SegmentEntry: Sendable {
        var ref: SegmentRef
        /// Nil for a segment that was never read (a windowed load), so it can't be matched.
        var fingerprint: Int?
    }

    /// The layout a chat was last written (or loaded) with.
    struct Layout: Sendable {
        var token: String
        var complete: Bool
        var activityMs: Double?
        var retained: Bool
        var forwardedSenderRefreshPending: Bool
        var segments: [SegmentEntry]
        /// Of the items from `fingerprintOffset` on (a windowed load reads only the newest).
        var itemFingerprints: [Int]
        var fingerprintOffset = 0
        /// The manifest's date when this was recorded; a manifest changed by anyone else voids it.
        var manifestDate: Date?
    }

    enum SegmentedRead {
        case loaded(Snapshot, Layout)
        case missing(String)
        case unavailable(String)
        case corrupt(String)
    }

    /// A segment ends after this many items...
    static let maxSegmentItems = 256
    /// ...or after an item whose id hashes to a multiple of this.
    static let segmentBoundaryModulus: UInt64 = 64

    private static let lastStats = Mutex<SaveResult?>(nil)

    /// What the latest write through the writer did (tests and benchmarks).
    public static var lastSaveStats: SaveResult? { self.lastStats.withLock { $0 } }

    /// By cache root (the app has one), so parallel tests with their own roots don't count each other's.
    private static let segmentDecodes = Mutex<[String: Int]>([:])

    /// Segment files decoded so far in this process under `root` (tests check what a save or read touches).
    static func segmentDecodeCount(root: URL) -> Int {
        let key = root.standardizedFileURL.path(percentEncoded: false)
        return self.segmentDecodes.withLock { $0[key, default: 0] }
    }

    static func recordSaveStats(_ result: SaveResult) {
        self.lastStats.withLock { $0 = result }
    }

    package static func segmentsDirectory(of manifest: URL) -> URL {
        manifest.deletingPathExtension().appendingPathExtension("segments")
    }

    /// FNV-1a: unlike `Hashable`, the same in every process, so boundaries don't move between launches.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Content-defined segments: an item that ends one depends only on its id, so appending or
    /// prepending items leaves the other segments as they were.
    static func segmentRanges(_ items: [ChatItem]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for index in items.indices {
            let full = index - start + 1 >= self.maxSegmentItems
            if full || self.stableHash(items[index].id) % self.segmentBoundaryModulus == 0 {
                ranges.append(start..<(index + 1))
                start = index + 1
            }
        }
        if start < items.count { ranges.append(start..<items.count) }
        return ranges
    }

    /// In-memory change detector for one item: `ChatItem.hashValue` plus what `ImageRef`'s hash
    /// leaves out although it's encoded (`base64`).
    static func itemFingerprint(_ item: ChatItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item)
        for case let .image(image) in item.blocks { hasher.combine(image.base64) }
        return hasher.finalize()
    }

    static func fingerprint(_ itemFingerprints: ArraySlice<Int>) -> Int {
        var hasher = Hasher()
        hasher.combine(itemFingerprints.count)
        for value in itemFingerprints { hasher.combine(value) }
        return hasher.finalize()
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// Whether a read failed because the file isn't there.
    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
            || error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    enum SegmentLoad {
        case items([ChatItem])
        case missing
        case unavailable(String)
        case corrupt(String)
    }

    /// Reads one segment. Only content problems are `corrupt`; an unreadable file that exists is
    /// `unavailable` (permissions, data protection, I/O that may pass).
    static func loadSegment(_ ref: SegmentRef, in directory: URL) -> SegmentLoad {
        // Names come from the manifest: never let one point outside the directory.
        guard !ref.file.isEmpty, !ref.file.contains("/"), ref.file != "..", ref.file != "." else {
            return .corrupt("bad segment name")
        }
        let url = directory.appending(path: ref.file)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if self.isMissing(error) {
                return .missing
            }
            return .unavailable("segment \(ref.file) unreadable: \(error.localizedDescription)")
        }
        guard !data.isEmpty else { return .corrupt("segment \(ref.file) is empty") }
        let segment: [ChatItem]
        do {
            segment = try JSONDecoder().decode([ChatItem].self, from: data).map { item in
                var projected = item
                projected.projectLegacyLocationForDisplay()
                return projected
            }
        } catch {
            return .corrupt("segment \(ref.file) is not a transcript: \(self.describe(error))")
        }
        guard segment.count == ref.count, segment.first?.id == ref.firstId, segment.last?.id == ref.lastId else {
            return .corrupt("segment \(ref.file) doesn't match its manifest entry")
        }
        let root = directory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        self.segmentDecodes.withLock { $0[root, default: 0] += 1 }
        return .items(segment)
    }

    /// Reads the segments `range` of a manifest (all by default). The snapshot holds just those
    /// items; `layout` describes the whole manifest, with fingerprints only for what was read.
    static func readSegments(_ manifest: Manifest, manifestURL: URL, range: Range<Int>? = nil) -> SegmentedRead {
        let directory = self.segmentsDirectory(of: manifestURL)
        let range = range ?? manifest.segments.indices
        var items: [ChatItem] = []
        var fingerprints: [Int] = []
        var entries = manifest.segments.map { SegmentEntry(ref: $0, fingerprint: nil) }
        for index in range {
            let ref = manifest.segments[index]
            switch self.loadSegment(ref, in: directory) {
            case .missing: return .missing(ref.file)
            case let .unavailable(reason): return .unavailable(reason)
            case let .corrupt(reason): return .corrupt(reason)
            case let .items(segment):
                let own = segment.map(self.itemFingerprint)
                entries[index].fingerprint = self.fingerprint(own[...])
                fingerprints += own
                items += segment
            }
        }
        let snapshot = Snapshot(items: items, complete: manifest.complete, activityMs: manifest.activityMs,
                                retained: manifest.retained,
                                forwardedSenderRefreshPending: manifest.forwardedSenderRefreshPending)
        let offset = manifest.segments[..<range.lowerBound].reduce(0) { $0 + $1.count }
        let layout = Layout(token: manifest.token, complete: manifest.complete, activityMs: manifest.activityMs,
                            retained: manifest.retained,
                            forwardedSenderRefreshPending: manifest.forwardedSenderRefreshPending,
                            segments: entries, itemFingerprints: fingerprints,
                            fingerprintOffset: offset)
        return .loaded(snapshot, layout)
    }
}

extension TranscriptCache.Writer {
    typealias Cache = TranscriptCache

    func forgetLayout(_ url: URL) {
        self.layouts[url] = nil
        self.recency.removeAll { $0 == url }
        self.resetPrimeStartCountForTesting(url)
    }

    private func remember(_ layout: Cache.Layout, for url: URL) {
        self.recency.removeAll { $0 == url }
        self.recency.append(url)
        self.layouts[url] = layout
        // Counted per cache root (the app has one), so separate roots (tests) never evict each other's.
        let root = Self.cacheRoot(of: url)
        var sameRoot = self.recency.indices.filter { Self.cacheRoot(of: self.recency[$0]) == root }
        while sameRoot.count > Self.maxLayouts {
            let oldest = sameRoot.removeFirst()
            self.layouts[self.recency[oldest]] = nil
            self.recency.remove(at: oldest)
            sameRoot = sameRoot.map { $0 - 1 }
        }
    }

    /// `root/<gateway>/<chat>.json` → `root`.
    private static func cacheRoot(of url: URL) -> URL {
        url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Records what a load found so the first save after launch writes only what changed.
    func prime(_ url: URL, layout: Cache.Layout) async {
        if self.trackedPrimeURLsForTesting.contains(url) {
            self.primeStartsForTesting[url, default: 0] += 1
        }
        if let delay = self.primeDelaysForTesting[url] { try? await Task.sleep(for: delay) }
        guard self.layouts[url] == nil, layout.manifestDate != nil else { return }
        self.remember(layout, for: url)
    }

    /// Writes the segments of `items` that no entry in `reusable` already holds.
    private func build(_ items: [ChatItem], fingerprints: [Int], reusable: [Int: Cache.SegmentEntry], directory: URL,
                       result: inout Cache.SaveResult) throws -> (entries: [Cache.SegmentEntry], reusedAll: Bool)
    {
        var entries: [Cache.SegmentEntry] = []
        var reusedAll = true
        for range in Cache.segmentRanges(items) {
            let fingerprint = Cache.fingerprint(fingerprints[range])
            if let old = reusable[fingerprint], old.ref.count == range.count,
               old.ref.firstId == items[range.lowerBound].id, old.ref.lastId == items[range.upperBound - 1].id,
               FileManager.default.fileExists(atPath: directory.appending(path: old.ref.file).path(percentEncoded: false))
            {
                entries.append(old)
                continue
            }
            reusedAll = false
            let name = "\(UUID().uuidString.lowercased()).json"
            let data = try JSONEncoder().encode(Array(items[range]))
            try data.write(to: directory.appending(path: name), options: self.writeOptions)
            result.bytesWritten += data.count
            result.filesWritten += 1
            entries.append(Cache.SegmentEntry(
                ref: Cache.SegmentRef(file: name, count: range.count, firstId: items[range.lowerBound].id,
                                      lastId: items[range.upperBound - 1].id),
                fingerprint: fingerprint))
        }
        return (entries, reusedAll)
    }

    /// Writes the manifest and sidecar, then removes segments nothing references. Returns the token.
    private func commit(_ manifest: Cache.Manifest, url: URL, directory: URL, result: inout Cache.SaveResult) throws {
        let fileManager = FileManager.default
        let metaURL = url.appendingPathExtension("meta")
        // The sidecar goes first and comes back only once the manifest is written, so it
        // never vouches for a transcript that isn't there.
        try? fileManager.removeItem(at: metaURL)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: url, options: self.writeOptions)
        let meta = try JSONEncoder().encode(Cache.Meta(
            complete: manifest.complete, activityMs: manifest.activityMs, version: manifest.version,
            retained: manifest.retained,
            forwardedSenderRefreshPending: manifest.forwardedSenderRefreshPending))
        try meta.write(to: metaURL, options: self.writeOptions)
        result.bytesWritten += manifestData.count + meta.count
        result.filesWritten += 2
        let referenced = Set(manifest.segments.map(\.file))
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            where !referenced.contains(name)
        {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    /// Writes only the segments that changed, then the manifest and sidecar, then removes
    /// segments nothing references. A crash at any point leaves a manifest whose segments all
    /// exist. Unchanged transcripts touch nothing. With `keepingOlder`, `snapshot.items` is the
    /// newest window of the stored transcript and what's stored before it stays as it is.
    func write(_ snapshot: Cache.Snapshot, to url: URL, keepingOlder: Bool = false) -> Cache.SaveResult {
        let fileManager = FileManager.default
        let metaURL = url.appendingPathExtension("meta")
        let directory = Cache.segmentsDirectory(of: url)
        var result = Cache.SaveResult()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if keepingOlder, let windowed = try self.writeWindow(snapshot, to: url, directory: directory, result: &result) {
                return windowed
            }
            let items = snapshot.items
            let fingerprints = items.map(Cache.itemFingerprint)

            var baseline = self.layouts[url]
            if let known = baseline {
                let manifestDate = Cache.modificationDate(url)
                if manifestDate == nil || manifestDate != known.manifestDate { baseline = nil }
            }
            var reusable: [Int: Cache.SegmentEntry] = [:]
            for entry in baseline?.segments ?? [] {
                if let fingerprint = entry.fingerprint, reusable[fingerprint] == nil { reusable[fingerprint] = entry }
            }
            let (entries, reusedAll) = try self.build(
                items, fingerprints: fingerprints, reusable: reusable, directory: directory, result: &result)
            let pendingRefresh = self.pendingForwardedRefresh(snapshot, existing: baseline?.forwardedSenderRefreshPending ?? false)

            if let baseline, reusedAll, baseline.complete == snapshot.complete, baseline.activityMs == snapshot.activityMs,
               baseline.retained == snapshot.retained, baseline.forwardedSenderRefreshPending == pendingRefresh,
               baseline.segments.map(\.ref) == entries.map(\.ref),
               fileManager.fileExists(atPath: metaURL.path(percentEncoded: false))
            {
                self.remember(baseline, for: url)
                result.unchanged = true
                return result
            }

            let token = String(UInt64.random(in: .min ... .max))
            try self.commit(
                Cache.Manifest(version: snapshot.version, complete: snapshot.complete, activityMs: snapshot.activityMs,
                               retained: snapshot.retained, forwardedSenderRefreshPending: pendingRefresh,
                               token: token, segments: entries.map(\.ref)),
                url: url, directory: directory, result: &result)

            let date = Cache.modificationDate(url)
            self.remember(
                Cache.Layout(token: token, complete: snapshot.complete, activityMs: snapshot.activityMs,
                             retained: snapshot.retained, forwardedSenderRefreshPending: pendingRefresh,
                             segments: entries, itemFingerprints: fingerprints,
                             manifestDate: date),
                for: url)
            result.modified = date ?? Date()
            if let baseline {
                var prefix = 0
                if baseline.fingerprintOffset == 0 {
                    let limit = min(baseline.itemFingerprints.count, fingerprints.count)
                    while prefix < limit, baseline.itemFingerprints[prefix] == fingerprints[prefix] { prefix += 1 }
                } else {
                    prefix = Self.leadingUnchangedItems(old: baseline.segments.map(\.ref), new: entries.map(\.ref))
                }
                result.change = .tail(unchangedPrefix: prefix, baseToken: baseline.token, token: token)
            } else {
                result.change = .full(token: token)
            }
            return result
        } catch {
            // A missing cache only costs a refetch.
            self.forgetLayout(url)
            try? fileManager.removeItem(at: metaURL)
            TranscriptCache.logger.error("Couldn't write cached transcript \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return Cache.SaveResult(bytesWritten: result.bytesWritten, filesWritten: result.filesWritten)
        }
    }

    /// Items held by the leading segments that are the same in both.
    private static func leadingUnchangedItems(old: [Cache.SegmentRef], new: [Cache.SegmentRef]) -> Int {
        var count = 0
        for (a, b) in zip(old, new) {
            guard a == b else { break }
            count += a.count
        }
        return count
    }

    /// The window save of `write`. Nil when the window doesn't join what's stored (no manifest, or
    /// none of its items is on disk), so the caller saves it as the whole transcript instead;
    /// never splices across a gap. A stored transcript that can't be read now is left alone.
    private func writeWindow(_ snapshot: Cache.Snapshot, to url: URL, directory: URL,
                             result: inout Cache.SaveResult) throws -> Cache.SaveResult?
    {
        let fileManager = FileManager.default
        let metaURL = url.appendingPathExtension("meta")
        let stored: Cache.Manifest
        let storedData: Data
        do {
            storedData = try Data(contentsOf: url)
        } catch {
            return fileManager.fileExists(atPath: url.path(percentEncoded: false)) ? Cache.SaveResult() : nil
        }
        guard let peek = try? JSONDecoder().decode(Cache.VersionPeek.self, from: storedData),
              Cache.manifestVersions.contains(peek.version),
              let decoded = try? JSONDecoder().decode(Cache.Manifest.self, from: storedData)
        else { return nil }
        stored = decoded
        let items = snapshot.items
        guard let first = items.first else {
            result.unchanged = true
            return result
        }
        let ids = Set(items.map(\.id))
        guard let joined = stored.segments.firstIndex(where: { ids.contains($0.lastId) }) else { return nil }

        // The window starts in the first segment ending inside it, or, if that segment's last
        // item was replaced, the one before.
        var boundary: (index: Int, items: [ChatItem], position: Int)?
        for index in [joined, joined - 1] where index >= 0 && boundary == nil {
            switch Cache.loadSegment(stored.segments[index], in: directory) {
            case let .items(segment):
                if let position = segment.firstIndex(where: { $0.id == first.id }) { boundary = (index, segment, position) }
            case .unavailable: return Cache.SaveResult()
            case .missing, .corrupt: return nil
            }
        }
        guard let boundary else { return nil }

        let kept = Array(boundary.items[..<boundary.position])
        var older = Array(stored.segments[..<boundary.index])
        let region = kept + items
        var total = older.reduce(region.count) { $0 + $1.count }
        var dropped = false
        while let oldest = older.first, total - oldest.count >= Cache.maxItems {
            total -= oldest.count
            older.removeFirst()
            dropped = true
        }

        let known = self.layouts[url].flatMap { $0.token == stored.token ? $0 : nil }
        var fingerprintsByFile: [String: Int] = [:]
        var reusable: [Int: Cache.SegmentEntry] = [:]
        for entry in known?.segments ?? [] {
            guard let fingerprint = entry.fingerprint else { continue }
            fingerprintsByFile[entry.ref.file] = fingerprint
            if reusable[fingerprint] == nil { reusable[fingerprint] = entry }
        }
        let boundaryEntry = Cache.SegmentEntry(
            ref: stored.segments[boundary.index], fingerprint: Cache.fingerprint(boundary.items.map(Cache.itemFingerprint)[...]))
        reusable[boundaryEntry.fingerprint ?? 0] = boundaryEntry

        let fingerprints = region.map(Cache.itemFingerprint)
        let built = try self.build(region, fingerprints: fingerprints, reusable: reusable, directory: directory, result: &result)
        let olderEntries = older.map { Cache.SegmentEntry(ref: $0, fingerprint: fingerprintsByFile[$0.file]) }
        let entries = olderEntries + built.entries
        let olderCount = older.reduce(0) { $0 + $1.count }
        let retained = stored.retained || snapshot.retained || dropped
        let pendingRefresh = self.pendingForwardedRefresh(snapshot, existing: stored.forwardedSenderRefreshPending)

        if !dropped, built.reusedAll, entries.map(\.ref) == stored.segments,
           stored.activityMs == snapshot.activityMs, stored.retained == retained,
           stored.forwardedSenderRefreshPending == pendingRefresh,
           fileManager.fileExists(atPath: metaURL.path(percentEncoded: false))
        {
            self.remember(
                Cache.Layout(token: stored.token, complete: stored.complete && !dropped, activityMs: stored.activityMs,
                             retained: stored.retained, forwardedSenderRefreshPending: pendingRefresh,
                             segments: entries, itemFingerprints: fingerprints,
                             fingerprintOffset: olderCount, manifestDate: Cache.modificationDate(url)),
                for: url)
            result.unchanged = true
            return result
        }

        let token = String(UInt64.random(in: .min ... .max))
        try self.commit(
            Cache.Manifest(version: snapshot.version, complete: stored.complete && !dropped, activityMs: snapshot.activityMs,
                           retained: retained, forwardedSenderRefreshPending: pendingRefresh,
                           token: token, segments: entries.map(\.ref)),
            url: url, directory: directory, result: &result)
        let date = Cache.modificationDate(url)
        self.remember(
            Cache.Layout(token: token, complete: stored.complete && !dropped, activityMs: snapshot.activityMs, retained: retained,
                         forwardedSenderRefreshPending: pendingRefresh,
                         segments: entries, itemFingerprints: fingerprints, fingerprintOffset: olderCount,
                         manifestDate: date),
            for: url)
        result.modified = date ?? Date()
        result.complete = stored.complete && !dropped
        result.older = older
        result.boundaryKept = kept
        result.change = dropped
            ? .full(token: token)
            : .tail(unchangedPrefix: Self.leadingUnchangedItems(old: stored.segments, new: entries.map(\.ref)),
                    baseToken: stored.token, token: token)
        return result
    }

    private func pendingForwardedRefresh(_ snapshot: Cache.Snapshot, existing: Bool) -> Bool {
        if snapshot.forwardedSenderRefreshCompleted { return false }
        return snapshot.forwardedSenderRefreshPending || existing
    }
}
