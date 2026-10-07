import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2))) struct QuickLookFileOwnershipTests {
    @Test func openingAndClosingOnePreviewPreservesTheOtherFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookOwners-" + UUID().uuidString, isDirectory: true)
        do {
            let bytes = DemoGateway.richRenderingPDF()
            let first = try await Task.detached { try FilePreviewFiles.write(bytes, name: "A.pdf", mimeType: "application/pdf", in: root) }.value
            let initial = await Task.detached { try? Data(contentsOf: first) }.value
            #expect(initial == bytes && !bytes.isEmpty)
            let second = try await Task.detached { try FilePreviewFiles.write(bytes, name: "B.pdf", mimeType: "application/pdf", in: root) }.value
            let afterOpen = await Task.detached { (try? Data(contentsOf: first), try? Data(contentsOf: second)) }.value
            #expect(afterOpen.0 == bytes, "opening B must retain A's presented file")
            #expect(afterOpen.1 == bytes && first != second && second.lastPathComponent == "B.pdf")
            #if DEBUG
            let probe = QuickLookCleanupProbe()
            await FilePreviewFiles.dismiss(first, in: root, probe: probe)
            #expect(probe.counts.main == 0 && probe.counts.worker == 1, "actual dismissal disk cleanup must run off Main")
            #else
            await FilePreviewFiles.dismiss(first, in: root)
            #endif
            let afterClose = await Task.detached { try? Data(contentsOf: second) }.value
            #expect(afterClose == bytes, "dismissing A must retain B's presented file")
        } catch {
            await Task.detached { FilePreviewFiles.clear(in: root) }.value
            throw error
        }
        await Task.detached { FilePreviewFiles.clear(in: root) }.value
    }

    @Test func currentPreviewAndRealWriteFailureControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookControl-" + UUID().uuidString, isDirectory: true)
        let control = await Task.detached { () async -> Bool in
            defer { FilePreviewFiles.clear(in: root) }
            guard let url = try? FilePreviewFiles.write(Data([1, 2]), name: "Current.pdf", mimeType: "application/pdf", in: root),
                  (try? Data(contentsOf: url)) == Data([1, 2]) else { return false }
            await FilePreviewFiles.dismiss(url, in: root)
            let removed = !FileManager.default.fileExists(atPath: url.path)
            // Existing name policy allows a single component; a nonexistent nested name is sanitized.
            return removed && FilePreviewFiles.fileName("../Current.pdf", mimeType: nil) == "Current.pdf"
        }.value
        #expect(control)
        let failed = await Task.detached { () async -> Bool in
            let parent = root.appendingPathComponent("blocking", isDirectory: false)
            defer { FilePreviewFiles.clear(in: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data([1]).write(to: parent)
            } catch { return false }
            do {
                _ = try FilePreviewFiles.write(Data([2]), name: "No.pdf", mimeType: nil, in: parent.appendingPathComponent("child", isDirectory: true))
                return false
            } catch { return true }
        }.value
        #expect(failed)
    }
}
