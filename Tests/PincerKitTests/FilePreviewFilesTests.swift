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
        // Another window's preview retains the first owner's file.
        let second = try FilePreviewFiles.write(Data("two".utf8), name: "b.csv", mimeType: "text/csv", in: root)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        FilePreviewFiles.clear(in: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func onlyDownloadableNonTextFilesArePreviewed() {
        #expect(FilePreviewFiles.isPreviewable(FileRef(name: "a.pdf", artifactId: "x", mimeType: "application/pdf")))
        #expect(!FilePreviewFiles.isPreviewable(FileRef(name: "a.sh", artifactId: "x", mimeType: "text/x-shellscript")))
        #expect(!FilePreviewFiles.isPreviewable(FileRef(name: "a.pdf", mimeType: "application/pdf")))
    }

    @Test func requestedFormatsAreCoveredForChatPreview() {
        let markdown = FileRef(name: "notes.md", artifactId: "a1", mimeType: "text/markdown")
        #expect(markdown.isText)
        #expect(!FilePreviewFiles.isPreviewable(markdown), "markdown expands inline as text")

        let html = FileRef(name: "report.html", artifactId: "a2", mimeType: "text/html")
        #expect(html.isText)
        #expect(!FilePreviewFiles.isPreviewable(html), "HTML expands inline as text")

        let docx = FileRef(
            name: "brief.docx", artifactId: "a3",
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(!docx.isText)
        #expect(FilePreviewFiles.isPreviewable(docx), "DOCX opens in Quick Look")

        let pdf = FileRef(name: "spec.pdf", artifactId: "a4", mimeType: "application/pdf")
        #expect(!pdf.isText)
        #expect(FilePreviewFiles.isPreviewable(pdf), "PDF opens in Quick Look")
    }

    @Test func addsDocxExtensionFromMimeType() {
        let file = FilePreviewFiles.fileName(
            "brief",
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(file == "brief.docx")
    }

    @Test func addsPopularOfficeExtensionsFromMimeTypes() {
        #expect(FilePreviewFiles.fileName("slides", mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation")
            == "slides.pptx")
        #expect(FilePreviewFiles.fileName("budget", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            == "budget.xlsx")
        #expect(FilePreviewFiles.fileName("archive", mimeType: "application/zip") == "archive.zip")
    }

    @Test func popularDocumentTypesUseQuickLookPath() {
        #expect(FilePreviewFiles.isPreviewable(FileRef(
            name: "deck.pptx", artifactId: "p1",
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation")))
        #expect(FilePreviewFiles.isPreviewable(FileRef(
            name: "sheet.xlsx", artifactId: "p2",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")))
        #expect(FilePreviewFiles.isPreviewable(FileRef(
            name: "archive.zip", artifactId: "p3", mimeType: "application/zip")))
    }

    @Test func demoPDFIsAPDF() {
        let pdf = DemoGateway.richRenderingPDF()
        #expect(pdf.count > 500)
        #expect(pdf.prefix(5) == Data("%PDF-".utf8))
    }
}
