import Foundation
import Testing
@testable import PincerKit

/// The `controlUi.linkPreview` cache behind browser page cards (#976).
@MainActor
@Suite("Browser page previews")
struct BrowserPagePreviewsTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]).base64EncodedString()

    static func response(title: String? = "Docs", image: String? = nil, favicon: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let title { object["title"] = .string(title) }
        if let image { object["imageDataUrl"] = .string(image) }
        if let favicon { object["faviconDataUrl"] = .string(favicon) }
        return .object(object)
    }

    @Test func acceptsPNGJPEGAndIconDataURLs() throws {
        let image = try #require(BrowserPagePreviews.imageRef(dataURL: "data:image/png;base64,\(Self.png)", limit: 350_000))
        #expect(image.mimeType == "image/png" && image.base64 == Self.png)
        #expect(BrowserPagePreviews.imageRef(dataURL: "data:image/jpeg;base64,\(Self.png)", limit: 350_000)?.mimeType == "image/jpeg")
        #expect(BrowserPagePreviews.imageRef(dataURL: "data:image/x-icon;base64,\(Self.png)", limit: 90_000)?.mimeType == "image/x-icon")
    }

    @Test func rejectsOtherMimeTypesAndMalformedURLs() {
        for bad in ["data:image/svg+xml;base64,\(Self.png)", "data:image/gif;base64,\(Self.png)", "data:text/html;base64,\(Self.png)",
                    "data:image/png,\(Self.png)", "https://example.com/a.png", "data:image/png;base64,", "data:image/png;base64,@@@not-base64@@@", ""] {
            #expect(BrowserPagePreviews.imageRef(dataURL: bad, limit: 350_000) == nil, "\(bad.prefix(40))")
        }
    }

    @Test func enforcesTheSizeCaps() {
        let prefix = "data:image/png;base64,"
        let ok = prefix + String(repeating: "A", count: 349_976)
        let big = prefix + String(repeating: "A", count: 349_980)
        #expect(BrowserPagePreviews.imageRef(dataURL: ok, limit: BrowserPagePreviews.maxImageChars) != nil)
        #expect(BrowserPagePreviews.imageRef(dataURL: big, limit: BrowserPagePreviews.maxImageChars) == nil)
        let icon = "data:image/x-icon;base64," + String(repeating: "A", count: 90_000)
        #expect(BrowserPagePreviews.imageRef(dataURL: icon, limit: BrowserPagePreviews.maxFaviconChars) == nil, "favicons cap at 90k chars")
    }

    @Test func parsesATitleImageAndFavicon() throws {
        let (preview, bytes) = try #require(BrowserPagePreviews.parse(Self.response(
            title: "  Docs ", image: "data:image/png;base64,\(Self.png)", favicon: "data:image/x-icon;base64,\(Self.png)")))
        #expect(preview.title == "Docs" && preview.image != nil && preview.favicon != nil)
        #expect(bytes >= Self.png.utf8.count * 2)
    }

    @Test func emptyOrUnusableResponsesParseToNil() {
        #expect(BrowserPagePreviews.parse([:]) == nil, "the gateway answers {} when disabled")
        #expect(BrowserPagePreviews.parse(Self.response(title: nil, image: "data:image/svg+xml;base64,\(Self.png)")) == nil)
        #expect(BrowserPagePreviews.parse(Self.response(title: "   ")) == nil)
        let titleOnly = BrowserPagePreviews.parse(Self.response(title: "T"))?.0
        #expect(titleOnly?.title == "T" && titleOnly?.image == nil)
    }

    @Test func oversizeImageIsDroppedButTheRestStays() throws {
        let huge = "data:image/png;base64," + String(repeating: "A", count: 400_000)
        let (preview, _) = try #require(BrowserPagePreviews.parse(Self.response(title: "T", image: huge)))
        #expect(preview.image == nil && preview.title == "T")
    }

    @Test func screenshotHookStoresAndClearsPerTab() {
        let previews = BrowserPagePreviews()
        let shot = ImageRef(artifactId: nil, base64: Self.png, url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil)
        #expect(previews.screenshot(forTab: "host|p|T1") == nil)
        previews.setScreenshot(shot, forTab: "host|p|T1")
        #expect(previews.screenshot(forTab: "host|p|T1") == shot)
        #expect(previews.screenshot(forTab: "host|p|T2") == nil, "keyed per tab")
        previews.setScreenshot(nil, forTab: "host|p|T1")
        #expect(previews.screenshot(forTab: "host|p|T1") == nil)
        previews.setScreenshot(shot, forTab: "host|p|T1")
        previews.reset()
        #expect(previews.screenshot(forTab: "host|p|T1") == nil, "a profile switch clears screenshots")
    }

    @Test func loadIsANoOpWithoutAnAdvertisedConnectedGateway() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        #expect(!gateway.advertises("controlUi.linkPreview"))
        let url = try #require(URL(string: "https://example.com/"))
        gateway.pagePreviews.load(url)
        #expect(gateway.pagePreviews.requestCount == 0)
        #expect(gateway.pagePreviews.preview(for: url) == nil)
    }

    @Test func hostGuardsSkipLoopbackPrivateLocalAndIPLiterals() {
        func fetchable(_ text: String) -> Bool { BrowserPagePreviews.isFetchable(URL(string: text)!) }
        for bad in ["http://localhost/", "http://localhost:3000/a", "http://app.localhost/", "https://printer.local/", "http://127.0.0.1/", "http://10.0.0.5/",
                    "http://192.168.1.10/", "http://172.16.0.1/", "http://169.254.169.254/latest", "http://8.8.8.8/", "http://[::1]/", "http://[fe80::1]/",
                    "http://intranet/", "http://nas.lan/", "http://2130706433/", "ftp://example.com/", "file:///etc/hosts"] {
            #expect(!fetchable(bad), "\(bad) is skipped")
        }
        for good in ["https://example.com/", "http://docs.example.co.uk/a?b=1", "https://www.marriott.com/x"] {
            #expect(fetchable(good), "\(good) is fetched")
        }
    }

    @Test func emptyResponseIsNotAPreview() {
        #expect(BrowserPagePreviews.parse([:]) == nil, "{} parses to nil so load records a negative result")
    }
}
