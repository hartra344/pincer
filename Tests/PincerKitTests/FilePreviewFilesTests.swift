import Foundation
import Testing
@testable import PincerKit

@Suite struct FilePreviewFilesTests {
    @Test func namesAreSingleSafeComponents() {
        #expect(FilePreviewFiles.fileName("report.pdf", mimeType: "application/pdf") == "report.pdf")
        #expect(FilePreviewFiles.fileName("../../etc/passwd", mimeType: nil) == "passwd")
        #expect(FilePreviewFiles.fileName(".hidden.pdf", mimeType: nil) == "hidden.pdf")
        #expect(FilePreviewFiles.fileName("..", mimeType: nil) == "file")
        #expect(FilePreviewFiles.fileName("a:b.pdf", mimeType: nil) == "a-b.pdf")
        #expect(FilePreviewFiles.fileName("summary", mimeType: "application/pdf; charset=binary") == "summary.pdf")
        let long = FilePreviewFiles.fileName(String(repeating: "x", count: 300) + ".pdf", mimeType: nil)
        #expect(long.count == 120 && long.hasSuffix(".pdf"))
    }

    @Test func writesInsideTheRootAndClears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PincerQuickLookTests-\(UUID().uuidString)")
        defer { FilePreviewFiles.clear(in: root) }
        let first = try FilePreviewFiles.write(Data("one".utf8), name: "../escape.pdf", mimeType: nil, in: root)
        #expect(first.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(first.lastPathComponent == "escape.pdf")
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        // A new preview replaces the old one.
        let second = try FilePreviewFiles.write(Data("two".utf8), name: "b.csv", mimeType: "text/csv", in: root)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        FilePreviewFiles.clear(in: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func onlyDownloadableNonTextFilesArePreviewed() {
        #expect(FilePreviewFiles.isPreviewable(FileRef(name: "a.pdf", artifactId: "x", mimeType: "application/pdf")))
        #expect(!FilePreviewFiles.isPreviewable(FileRef(name: "a.sh", artifactId: "x", mimeType: "text/x-shellscript")))
        #expect(!FilePreviewFiles.isPreviewable(FileRef(name: "a.pdf", mimeType: "application/pdf")))
    }

    @Test func demoPDFIsAPDF() {
        let pdf = DemoGateway.richRenderingPDF()
        #expect(pdf.count > 500)
        #expect(pdf.prefix(5) == Data("%PDF-".utf8))
    }
}
