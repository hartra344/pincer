import Foundation
import Testing
@testable import PincerKit

struct BrowserTabRefTests {
    private func details(_ tab: String) -> JSONValue { Fixtures.json(#"{"browserTab":\#(tab)}"#) }

    @Test func parsesAFullReference() throws {
        let ref = try #require(BrowserTabRef.parse(details(
            #"{"targetId":"T1","profile":"openclaw","target":"node","node":"n1","url":"https://docs.openclaw.ai/x","title":"Docs"}"#)))
        #expect(ref.targetId == "T1")
        #expect(ref.profile == "openclaw")
        #expect(ref.target == "node")
        #expect(ref.node == "n1")
        #expect(ref.url == URL(string: "https://docs.openclaw.ai/x"))
        #expect(ref.title == "Docs")
        #expect(ref.host == "docs.openclaw.ai")
    }

    @Test func needsATargetId() {
        #expect(BrowserTabRef.parse(nil) == nil)
        #expect(BrowserTabRef.parse(Fixtures.json("{}")) == nil)
        #expect(BrowserTabRef.parse(details(#"{"title":"x"}"#)) == nil)
        #expect(BrowserTabRef.parse(details(#"{"targetId":""}"#)) == nil)
        #expect(BrowserTabRef.parse(details(#""nope""#)) == nil)
    }

    @Test func dropsNonHTTPURLs() throws {
        for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "chrome://settings", "about:blank", "ftp://x.test/a"] {
            let ref = try #require(BrowserTabRef.parse(details(#"{"targetId":"T","url":"\#(url)"}"#)), "\(url)")
            #expect(ref.url == nil, "\(url) is dropped")
            #expect(ref.host == nil)
        }
        let http = try #require(BrowserTabRef.parse(details(#"{"targetId":"T","url":"http://localhost:3000/"}"#)))
        #expect(http.url != nil)
    }

    @Test func toleratesWrongTypes() throws {
        let ref = try #require(BrowserTabRef.parse(details(#"{"targetId":"T","profile":3,"url":9,"title":false,"node":[]}"#)))
        #expect(ref.profile == nil)
        #expect(ref.url == nil)
        #expect(ref.title == nil)
        #expect(ref.node == nil)
    }
}
