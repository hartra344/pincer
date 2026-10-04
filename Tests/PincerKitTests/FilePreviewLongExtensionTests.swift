import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct FilePreviewLongExtensionTests {
    @Test(arguments: [119, 120, 130])
    func extensionBoundaryCannotTrap(length: Int) async {
        let name = await Task.detached {
            FilePreviewFiles.fileName("a." + String(repeating: "x", count: length), mimeType: nil)
        }.value
        #expect(!name.isEmpty && name.count <= 120)
        #expect(!name.contains("/") && !name.contains("\\"))
        #expect(!name.hasPrefix("."))
        #expect(!(name as NSString).deletingPathExtension.isEmpty)
    }
    @Test func existingOrdinaryAndPathControlsRemainExact() async {
        let names = await Task.detached {
            [FilePreviewFiles.fileName("report.pdf", mimeType: "application/pdf"),
             FilePreviewFiles.fileName("../../etc/passwd", mimeType: nil),
             FilePreviewFiles.fileName(".hidden.pdf", mimeType: nil),
             FilePreviewFiles.fileName("summary", mimeType: "application/pdf"),
             FilePreviewFiles.fileName(String(repeating: "x", count: 300) + ".pdf", mimeType: nil)]
        }.value
        #expect(names == ["report.pdf", "passwd", "hidden.pdf", "summary.pdf", String(repeating: "x", count: 116) + ".pdf"])
    }
}
