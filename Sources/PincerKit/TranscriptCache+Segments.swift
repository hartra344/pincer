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
        /// Identifies this write; the search index uses it to know which save it last saw.
        var token: String
        var segments: [SegmentRef]

        private enum CodingKeys: String, CodingKey {
            case version, complete, activityMs, retained, token, segments
        }

        init(version: Int, complete: Bool, activityMs: Double?, retained: Bool, token: String, segments: [SegmentRef]) {
            self.version = version
            self.complete = complete
            self.activityMs = activityMs
            self.retained = retained
            self.token = token
            self.segments = segments
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try c.decode(Int.self, forKey: .version)
            self.complete = try c.decode(Bool.self, forKey: .complete)
            self.activityMs = try c.decodeIfPresent(Double.self, forKey: .activityMs)
            self.retained = try c.decodeIfPresent(Bool.self, forKey: .retained) ?? false
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

        public init(bytesWritten: Int = 0, filesWritten: Int = 0, unchanged: Bool = false) {
            self.bytesWritten = bytesWritten
            self.filesWritten = filesWritten
            self.unchanged = unchanged
        }
    }

    /// A segment as last written: in-memory only, so fingerprints are seeded per process.
    struct SegmentEntry: Sendable {
        var ref: SegmentRef
        var fingerprint: Int
    }

    /// The layout a chat was last written (or loaded) with.
    struct Layout: Sendable {
        var token: String
        var complete: Bool
        var activityMs: Double?
        var retained: Bool
        var segments: [SegmentEntry]
        var itemFingerprints: [Int]
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

    static func recordSaveStats(_ result: SaveResult) {
        self.lastStats.withLock { $0 = result }
    }

    static func segmentsDirectory(of manifest: URL) -> URL {
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

    /// Reads every segment of a manifest. Only content problems are `corrupt`; an unreadable file
    /// that exists is `unavailable` (permissions, data protection, I/O that may pass).
    static func readSegments(_ manifest: Manifest, manifestURL: URL) -> SegmentedRead {
        let directory = self.segmentsDirectory(of: manifestURL)
        var items: [ChatItem] = []
        var fingerprints: [Int] = []
        var entries: [SegmentEntry] = []
        for ref in manifest.segments {
            // Names come from the manifest: never let one point outside the directory.
            guard !ref.file.isEmpty, !ref.file.contains("/"), ref.file != "..", ref.file != "." else {
                return .corrupt("bad segment name")
            }
            let url = directory.appending(path: ref.file)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                if self.isMissing(error) || !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    return .missing(ref.file)
                }
                return .unavailable("segment \(ref.file) unreadable: \(error.localizedDescription)")
            }
            guard !data.isEmpty else { return .corrupt("segment \(ref.file) is empty") }
            let segment: [ChatItem]
            do {
                segment = try JSONDecoder().decode([ChatItem].self, from: data)
            } catch {
                return .corrupt("segment \(ref.file) is not a transcript: \(self.describe(error))")
            }
            guard segment.count == ref.count, segment.first?.id == ref.firstId, segment.last?.id == ref.lastId else {
                return .corrupt("segment \(ref.file) doesn't match its manifest entry")
            }
            let own = segment.map(\.hashValue)
            entries.append(SegmentEntry(ref: ref, fingerprint: self.fingerprint(own[...])))
            fingerprints += own
            items += segment
        }
        let snapshot = Snapshot(items: items, complete: manifest.complete, activityMs: manifest.activityMs,
                                retained: manifest.retained)
        let layout = Layout(token: manifest.token, complete: manifest.complete, activityMs: manifest.activityMs,
                            retained: manifest.retained, segments: entries, itemFingerprints: fingerprints)
        return .loaded(snapshot, layout)
    }
}

extension TranscriptCache.Writer {
    func forgetLayout(_ url: URL) {
        self.layouts[url] = nil
        self.recency.removeAll { $0 == url }
    }

    private func remember(_ layout: TranscriptCache.Layout, for url: URL) {
        self.recency.removeAll { $0 == url }
        self.recency.append(url)
        self.layouts[url] = layout
        while self.recency.count > Self.maxLayouts { self.layouts[self.recency.removeFirst()] = nil }
    }

    /// Records what a load found so the first save after launch writes only what changed.
    func prime(_ url: URL, layout: TranscriptCache.Layout) {
        guard self.layouts[url] == nil, layout.manifestDate != nil else { return }
        self.remember(layout, for: url)
    }

    /// Writes only the segments that changed, then the manifest and sidecar, then removes
    /// segments nothing references. A crash at any point leaves a manifest whose segments all
    /// exist. Unchanged transcripts touch nothing.
    func write(_ snapshot: TranscriptCache.Snapshot, to url: URL) -> TranscriptCache.SaveResult {
        typealias Cache = TranscriptCache
        let fileManager = FileManager.default
        let metaURL = url.appendingPathExtension("meta")
        let directory = Cache.segmentsDirectory(of: url)
        var result = Cache.SaveResult()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let items = snapshot.items
            let fingerprints = items.map(\.hashValue)

            var baseline = self.layouts[url]
            if let known = baseline {
                let manifestDate = Cache.modificationDate(url)
                if manifestDate == nil || manifestDate != known.manifestDate { baseline = nil }
            }
            var reusable: [Int: Cache.SegmentEntry] = [:]
            for entry in baseline?.segments ?? [] where reusable[entry.fingerprint] == nil { reusable[entry.fingerprint] = entry }

            var entries: [Cache.SegmentEntry] = []
            var reusedAll = true
            for range in Cache.segmentRanges(items) {
                let fingerprint = Cache.fingerprint(fingerprints[range])
                if let old = reusable[fingerprint], old.ref.count == range.count,
                   old.ref.firstId == items[range.lowerBound].id, old.ref.lastId == items[range.upperBound - 1].id,
                   fileManager.fileExists(atPath: directory.appending(path: old.ref.file).path(percentEncoded: false))
                {
                    entries.append(old)
                    continue
                }
                reusedAll = false
                let name = "\(UUID().uuidString.lowercased()).json"
                let data = try JSONEncoder().encode(Array(items[range]))
                try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtection])
                result.bytesWritten += data.count
                result.filesWritten += 1
                entries.append(Cache.SegmentEntry(
                    ref: Cache.SegmentRef(file: name, count: range.count, firstId: items[range.lowerBound].id,
                                          lastId: items[range.upperBound - 1].id),
                    fingerprint: fingerprint))
            }

            if let baseline, reusedAll, baseline.complete == snapshot.complete, baseline.activityMs == snapshot.activityMs,
               baseline.retained == snapshot.retained, baseline.segments.map(\.ref) == entries.map(\.ref),
               fileManager.fileExists(atPath: metaURL.path(percentEncoded: false))
            {
                self.remember(baseline, for: url)
                result.unchanged = true
                return result
            }

            let token = String(UInt64.random(in: .min ... .max))
            let manifest = Cache.Manifest(
                version: snapshot.version, complete: snapshot.complete, activityMs: snapshot.activityMs,
                retained: snapshot.retained, token: token, segments: entries.map(\.ref))
            // The sidecar goes first and comes back only once the manifest is written, so it
            // never vouches for a transcript that isn't there.
            try? fileManager.removeItem(at: metaURL)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: url, options: [.atomic, .completeFileProtection])
            let meta = try JSONEncoder().encode(Cache.Meta(
                complete: snapshot.complete, activityMs: snapshot.activityMs, version: snapshot.version,
                retained: snapshot.retained))
            try meta.write(to: metaURL, options: [.atomic, .completeFileProtection])
            result.bytesWritten += manifestData.count + meta.count
            result.filesWritten += 2

            let referenced = Set(entries.map(\.ref.file))
            for name in (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
                where !referenced.contains(name)
            {
                try? fileManager.removeItem(at: directory.appending(path: name))
            }

            let date = Cache.modificationDate(url)
            self.remember(
                Cache.Layout(token: token, complete: snapshot.complete, activityMs: snapshot.activityMs,
                             retained: snapshot.retained, segments: entries, itemFingerprints: fingerprints,
                             manifestDate: date),
                for: url)
            result.modified = date ?? Date()
            if let baseline {
                var prefix = 0
                let limit = min(baseline.itemFingerprints.count, fingerprints.count)
                while prefix < limit, baseline.itemFingerprints[prefix] == fingerprints[prefix] { prefix += 1 }
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
}
