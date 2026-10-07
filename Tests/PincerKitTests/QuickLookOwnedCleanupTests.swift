import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2))) struct QuickLookOwnedCleanupTests {
    @Test func retiredOwnerCleanupPreservesOtherOwnerAndRejectsUnownedPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookRetirement-" + UUID().uuidString, isDirectory: true)
        do {
            let values = try await Task.detached { () -> (URL, URL, URL) in
                let a = try FilePreviewFiles.write(Data([1]), name: "A.pdf", mimeType: nil, in: root)
                let b = try FilePreviewFiles.write(Data([2]), name: "B.pdf", mimeType: nil, in: root)
                let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
                try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
                let keep = unrelated.appendingPathComponent("keep.txt")
                try Data([3]).write(to: keep)
                return (a, b, keep)
            }.value
            await FilePreviewFiles.dismiss(values.2, in: root)
            await FilePreviewFiles.dismiss(values.0, in: root)
            let afterReplacement = await Task.detached {
                (!FileManager.default.fileExists(atPath: values.0.deletingLastPathComponent().path),
                 try? Data(contentsOf: values.1), try? Data(contentsOf: values.2))
            }.value
            #expect(afterReplacement.0 && afterReplacement.1 == Data([2]) && afterReplacement.2 == Data([3]))
            await FilePreviewFiles.dismiss(values.1, in: root)
            let afterClose = await Task.detached { !FileManager.default.fileExists(atPath: values.1.deletingLastPathComponent().path) }.value
            #expect(afterClose)
        } catch {
            await Task.detached { FilePreviewFiles.clear(in: root) }.value
            throw error
        }
        await Task.detached { FilePreviewFiles.clear(in: root) }.value
    }
}
