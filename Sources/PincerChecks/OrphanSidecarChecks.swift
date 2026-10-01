import Foundation
import PincerKit

@MainActor
func runOrphanSidecarChecks(root: URL) async {
    let gateway = UUID()
    guard let orphan = TranscriptCache.file(gatewayId: gateway, sessionKey: "orphan", root: root),
          let kept = TranscriptCache.file(gatewayId: gateway, sessionKey: "kept", root: root)
    else {
        check(false, "cache paths are available for sidecar cleanup")
        return
    }
    do {
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        let directory = orphan.deletingLastPathComponent()
        try Data("orphan metadata".utf8).write(to: orphan.appendingPathExtension("meta"))
        let orphanSegments = TranscriptCache.segmentsDirectory(of: orphan)
        try FileManager.default.createDirectory(at: orphanSegments, withIntermediateDirectories: true)
        try Data("orphan chunk".utf8).write(to: orphanSegments.appending(path: "chunk.json"))

        let temporaryMetadata = directory.appending(path: "\(TranscriptCache.digest(of: "temporary")).json.meta.tmp")
        let temporarySegments = directory.appending(path: "\(TranscriptCache.digest(of: "temporary")).segments.tmp")
        let malformedMetadata = directory.appending(path: "not-a-cache-digest.json.meta")
        try Data("temp metadata".utf8).write(to: temporaryMetadata)
        try Data("temp segments marker".utf8).write(to: temporarySegments)
        try Data("unrelated metadata".utf8).write(to: malformedMetadata)

        try Data("live manifest".utf8).write(to: kept)
        try Data("live metadata".utf8).write(to: kept.appendingPathExtension("meta"))
        let keptSegments = TranscriptCache.segmentsDirectory(of: kept)
        try FileManager.default.createDirectory(at: keptSegments, withIntermediateDirectories: true)
        try Data("live chunk".utf8).write(to: keptSegments.appending(path: "chunk.json"))

        await TranscriptCache.removeOrphanedSidecars(gatewayId: gateway, root: root)
        check(!FileManager.default.fileExists(atPath: orphan.appendingPathExtension("meta").path)
              && !FileManager.default.fileExists(atPath: orphanSegments.path),
              "orphan transcript metadata and segment directories are removed")
        check(FileManager.default.fileExists(atPath: kept.appendingPathExtension("meta").path)
              && FileManager.default.fileExists(atPath: keptSegments.path),
              "sidecars for a present transcript remain intact")
        check(FileManager.default.fileExists(atPath: temporaryMetadata.path)
              && FileManager.default.fileExists(atPath: temporarySegments.path)
              && FileManager.default.fileExists(atPath: malformedMetadata.path),
              "temporary and unrecognized files are outside sidecar cleanup")
    } catch {
        check(false, "sidecar cleanup fixture could be created: \(error.localizedDescription)")
    }
}
