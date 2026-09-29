import Foundation
import Testing
@testable import PincerKit

/// Fixtures and disk helpers for the v8 (segmented) transcript cache tests.
enum V8 {
    /// A realistic mix: user prompts, assistant replies (some several KB) and tool results.
    static func items(_ count: Int, from start: Int = 0) -> [ChatItem] {
        (start..<(start + count)).map { n in
            let time = Date(timeIntervalSince1970: 1_700_000_000 + Double(n))
            var item: ChatItem
            switch n % 3 {
            case 0:
                item = ChatItem(id: "u\(n)", role: .user, blocks: [.text("question \(n): how do I tune the widget?")], timestamp: time)
            case 1:
                let body = String(repeating: "Answer \(n) with some detail about widgets. ", count: n % 7 == 0 ? 90 : 4)
                item = ChatItem(id: "a\(n)", role: .assistant, blocks: [.text(body)], timestamp: time)
            default:
                item = ChatItem(id: "t\(n)", role: .toolResult, blocks: [.text("exit 0\n" + String(repeating: "log line \(n)\n", count: 12))], timestamp: time)
            }
            item.transcriptId = item.id
            return item
        }
    }

    static func manifestURL(_ gateway: UUID, _ key: String, _ root: URL) -> URL {
        TranscriptCache.file(gatewayId: gateway, sessionKey: key, root: root)!
    }

    static func segmentsDirectory(_ manifest: URL) -> URL {
        manifest.deletingPathExtension().appendingPathExtension("segments")
    }

    static func manifest(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func segmentFiles(_ manifest: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: self.segmentsDirectory(manifest).path)) ?? [])
    }

    static func referenced(_ manifest: URL) throws -> [String] {
        try (self.manifest(manifest)["segments"] as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
    }

    static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}

extension V8 {
    /// Saves through the stats hook (`TranscriptCache.saveReturningStats`).
    @discardableResult
    static func save(_ snapshot: TranscriptCache.Snapshot, _ gateway: UUID, _ key: String, _ root: URL) async -> TranscriptCache.SaveResult {
        await TranscriptCache.saveReturningStats(snapshot, gatewayId: gateway, sessionKey: key, root: root)
    }

    static func snapshot(_ items: [ChatItem], complete: Bool = true, activityMs: Double? = 7, retained: Bool = false) -> TranscriptCache.Snapshot {
        var snapshot = TranscriptCache.Snapshot(items: items, complete: complete, activityMs: activityMs)
        snapshot.retained = retained
        return snapshot
    }
}
