import Foundation
import Testing
@testable import PincerKit

/// Only a Gateway answer starts the 5-minute back-off for a page preview (#976).
@MainActor
@Suite("Browser page preview back-off")
struct BrowserPagePreviewBackoffTests {
    private let url = URL(string: "https://example.com/a")!

    @Test func emptyResponseBacksOff() {
        let previews = BrowserPagePreviews()
        previews.complete(url, response: [:], responded: true)
        #expect(previews.isBackingOff(url))
    }

    @Test func unparseableResponseBacksOff() {
        let previews = BrowserPagePreviews()
        previews.complete(url, response: ["imageDataUrl": "data:text/html;base64,AAAA"], responded: true)
        #expect(previews.isBackingOff(url))
    }

    @Test func disconnectOrCancellationDoesNotBackOff() {
        let previews = BrowserPagePreviews()
        previews.complete(url, response: nil, responded: false)
        #expect(!previews.isBackingOff(url))
    }

    @Test func footerKeepsPortOnHostFallback() throws {
        let page = try #require(BrowserPagePreview.parse(
            toolName: "browser",
            details: ["browserTab": ["targetId": "t", "profile": "p", "target": "host", "url": "https://example.com:8443/docs?a=1"]],
            isError: false, toolCallId: "c"))
        let footer = page.footer(linkTitle: nil)
        #expect(footer.title == "example.com:8443" && footer.subtitle == "/docs?a=1")
    }
}
