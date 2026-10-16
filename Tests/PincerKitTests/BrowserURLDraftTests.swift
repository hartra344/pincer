import Foundation
import Testing
@testable import PincerKit

struct BrowserURLDraftTests {
    private func norm(_ s: String) -> String? { BrowserURLDraft.normalize(s)?.absoluteString }

    @Test func hostsGetHTTPS() {
        #expect(norm("docs.openclaw.ai") == "https://docs.openclaw.ai")
        #expect(norm("docs.openclaw.ai/path?q=1") == "https://docs.openclaw.ai/path?q=1")
    }

    @Test func hostCaseAndSchemeCase() {
        #expect(BrowserURLDraft.normalize("EXAMPLE.com/path")?.host()?.lowercased() == "example.com")
        #expect(BrowserURLDraft.normalize("EXAMPLE.com/path")?.scheme == "https")
        #expect(BrowserURLDraft.normalize("HTTP://x.com")?.scheme?.lowercased() == "http")
        #expect(BrowserURLDraft.normalize("HTTP://x.com")?.host() == "x.com")
    }

    @Test func ipv6LiteralsGetHTTP() {
        let url = BrowserURLDraft.normalize("[::1]:3000")
        #expect(url?.scheme == "http")
        #expect(url?.port == 3000)
        #expect(norm("[::1]:3000") == "http://[::1]:3000")
    }

    @Test func hostPortIsNotParsedAsAScheme() {
        let url = BrowserURLDraft.normalize("localhost:3000")
        #expect(url?.scheme == "http")
        #expect(url?.host() == "localhost")
        #expect(url?.port == 3000)
        #expect(BrowserURLDraft.normalize("example.com:8443/x")?.scheme == "https")
        #expect(BrowserURLDraft.normalize("example.com:8443/x")?.port == 8443)
    }

    @Test func rejectsUserinfo() {
        for s in ["user:pass@example.com", "https://user:pass@example.com/", "http://user@example.com", "https://@example.com", "user@example.com"] {
            #expect(norm(s) == nil, "\(s)")
        }
    }

    @Test func localhostAndIPsGetHTTP() {
        #expect(norm("localhost") == "http://localhost")
        #expect(norm("localhost:3000") == "http://localhost:3000")
        #expect(norm("127.0.0.1:8080/x") == "http://127.0.0.1:8080/x")
        #expect(norm("192.168.1.5") == "http://192.168.1.5")
    }

    @Test func explicitSchemesKept() {
        #expect(norm("https://example.com/a") == "https://example.com/a")
        #expect(norm("http://example.com") == "http://example.com")
        #expect(norm("about:blank") == "about:blank")
    }

    @Test func trimsWhitespace() {
        #expect(norm("  https://example.com/a \n") == "https://example.com/a")
        #expect(norm("\t example.com ") == "https://example.com")
    }

    @Test func rejectsOtherSchemes() {
        for s in ["javascript:alert(1)", "JavaScript:alert(1)", "file:///etc/passwd", "data:text/html,hi",
                  "chrome://settings", "ftp://example.com/a", "view-source:https://example.com", "blob:https://x/1"] {
            #expect(norm(s) == nil, "\(s)")
        }
    }

    @Test func rejectsEmptyAndHostlessInput() {
        #expect(norm("") == nil)
        #expect(norm("   ") == nil)
        #expect(norm("hello") == nil)
        #expect(norm("foo") == nil)
        #expect(norm("my search terms") == nil)
        #expect(norm("hello world") == nil)
        #expect(norm("exa mple.com") == nil)
        #expect(norm("https://") == nil)
    }
}
