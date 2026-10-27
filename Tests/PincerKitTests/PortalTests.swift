import Foundation
import Security
import Testing
@testable import PincerKit

private func portalJSON(id: String = "p1", title: String = "Studio clock", publicUrl: String = "https://portal.test:4173/",
                        url: String? = "https://portal.test:4173/?openclaw_portal=secret", extra: String = "") -> JSONValue {
    let urlPart = url.map { #","url":"\#($0)","tokenQuery":"openclaw_portal=secret""# } ?? ""
    return Fixtures.json(#"{"id":"\#(id)","title":"\#(title)","port":4173,"listenPort":4173,"publicUrl":"\#(publicUrl)","createdAtMs":1000\#(urlPart)\#(extra)}"#)
}

private func samplePortal(_ publicUrl: String = "https://portal.test:4173/") -> PortalSummary {
    PortalSummary.parse(portalJSON(publicUrl: publicUrl, url: nil), allowsDemoScheme: true)!
}

struct PortalSummaryTests {
    @Test func fullEntryParses() throws {
        let value = portalJSON(extra: #","path":"/clock","description":"A clock","origin":"x","exposure":{"kind":"non-loopback","browserReachability":"unverified"},"future":1"#)
        let portal = try #require(PortalSummary.parse(value))
        #expect(portal.id == "p1" && portal.title == "Studio clock" && portal.port == 4173)
        #expect(portal.loadURL?.absoluteString == "https://portal.test:4173/?openclaw_portal=secret")
        #expect(portal.displayURL.absoluteString == "https://portal.test:4173/")
        #expect(portal.path == "/clock" && portal.details == "A clock")
        #expect(portal.exposure?.isLoopbackOnly == false)
        #expect(!portal.isRedacted)
    }

    @Test func redactedEntryHasNoLoadURL() throws {
        let portal = try #require(PortalSummary.parse(portalJSON(url: nil)))
        #expect(portal.loadURL == nil && portal.isRedacted)
        #expect(!portal.displayURL.absoluteString.contains("openclaw_portal"))
    }

    @Test func loopbackOnlyExposure() throws {
        let portal = try #require(PortalSummary.parse(portalJSON(extra: #","exposure":{"kind":"loopback-only","browserReachability":"unverified"}"#)))
        #expect(portal.exposure?.isLoopbackOnly == true)
    }

    @Test func junkIsDropped() {
        let junk = [
            Fixtures.json(#"{"title":"x","publicUrl":"https://a.test/"}"#),
            Fixtures.json(#"{"id":"a","publicUrl":"https://a.test/"}"#),
            Fixtures.json(#"{"id":"a","title":"x"}"#),
            Fixtures.json(#"{"id":"a","title":"x","publicUrl":"javascript:alert(1)"}"#),
            Fixtures.json(#"{"id":"a","title":"x","publicUrl":"file:///etc/passwd"}"#),
            Fixtures.json(#"{"id":"a","title":"x","publicUrl":"https://user:pw@a.test/"}"#),
            Fixtures.json(#"{"id":1,"title":2,"publicUrl":3}"#),
            Fixtures.json("[]"), Fixtures.json("null"),
        ]
        #expect(junk.allSatisfy { PortalSummary.parse($0) == nil })
    }

    @Test func loadURLOnAnotherOriginIsIgnored() throws {
        let portal = try #require(PortalSummary.parse(portalJSON(url: "https://evil.test/?openclaw_portal=secret")))
        #expect(portal.loadURL == nil)
    }

    @Test func theDemoSchemeIsOnlyForTheDemoGateway() throws {
        let demo = portalJSON(publicUrl: "demo-portal://studio-clock/", url: "demo-portal://studio-clock/?openclaw_portal=demo")
        #expect(PortalSummary.parse(demo) == nil)
        #expect(PortalSummary.parseList(["portals": .array([demo])])?.isEmpty == true)
        let allowed = try #require(PortalSummary.parse(demo, allowsDemoScheme: true))
        #expect(allowed.loadURL?.scheme == "demo-portal")
        #expect(PortalSummary.parseList(["portals": .array([demo])], allowsDemoScheme: true)?.count == 1)
        // The flag admits the demo scheme only; hostile schemes stay out.
        #expect(PortalSummary.parse(portalJSON(publicUrl: "javascript:alert(1)"), allowsDemoScheme: true) == nil)
    }

    @Test func relativePathMustStartWithSlash() throws {
        let portal = try #require(PortalSummary.parse(portalJSON(extra: #","path":"nope""#)))
        #expect(portal.path == nil)
    }

    @Test func listParsingSkipsBadEntriesAndDuplicates() throws {
        let reply = Fixtures.json(#"{"portals":[{"id":"a","title":"A","publicUrl":"https://a.test/"},{"id":"a","title":"A2","publicUrl":"https://a.test/"},{"id":"b"},"x"]}"#)
        let list = try #require(PortalSummary.parseList(reply))
        #expect(list.map(\.id) == ["a"])
        #expect(PortalSummary.parseList(Fixtures.json(#"{"nope":1}"#)) == nil)
        #expect(PortalSummary.parseList(Fixtures.json(#"{"portals":[]}"#))?.isEmpty == true)
    }

    @Test func overlongFieldsAreCapped() throws {
        let portal = try #require(PortalSummary.parse(portalJSON(title: String(repeating: "t", count: 900))))
        #expect(portal.title.count <= 200)
    }
}

struct PortalOriginPolicyTests {
    private func allows(_ string: String, portal: String = "https://portal.test:4173/", main: Bool = true) -> Bool {
        guard let url = URL(string: string) else { return false }
        return PortalOriginPolicy.allows(url, portal: samplePortal(portal), isMainFrame: main)
    }

    @Test func sameOriginIsAllowed() {
        #expect(allows("https://portal.test:4173/"))
        #expect(allows("https://portal.test:4173/deep/path?x=1#frag"))
        #expect(allows("https://portal.test:4173/?openclaw_portal=secret"))
    }

    @Test func otherPortSchemeOrHostIsRefused() {
        #expect(!allows("https://portal.test:4174/"))
        #expect(!allows("http://portal.test:4173/"))
        #expect(!allows("https://other.test:4173/"))
        #expect(!allows("https://sub.portal.test:4173/"))
        #expect(!allows("https://portal.test/"))
    }

    @Test func userinfoTrickIsRefused() {
        #expect(!allows("https://portal.test:4173@evil.test/"))
        #expect(!allows("https://portal.test@evil.test:4173/"))
        #expect(!allows("https://evil.test\\@portal.test:4173/"))
        #expect(!allows("https://user:pw@portal.test:4173/"))
    }

    @Test func nonWebSchemesAreRefused() {
        for url in ["pincer://open", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "ftp://portal.test:4173/",
                    "ws://portal.test:4173/", "blob:https://portal.test:4173/x", "about:srcdoc"] {
            #expect(!allows(url), "\(url)")
        }
    }

    @Test func aboutBlankAndSrcdocAreForSubframesOnly() {
        for url in ["about:blank", "about:srcdoc", "ABOUT:SRCDOC"] {
            #expect(allows(url, main: false), "\(url)")
            #expect(!allows(url, main: true), "\(url)")
        }
        #expect(!allows("about:blank#x", main: false))
        #expect(!allows("about:config", main: false))
    }

    // Attack cases from the product review (§2).
    @Test func loopbackAliasesAreDifferentOrigins() {
        #expect(!allows("http://127.0.0.1:8080/", portal: "http://localhost:8080/"))
        #expect(!allows("http://localhost:8080/", portal: "http://127.0.0.1:8080/"))
        #expect(!allows("http://[::1]:8080/", portal: "http://127.0.0.1:8080/"))
        #expect(!allows("http://127.0.0.1:8080/", portal: "http://[::1]:8080/"))
        #expect(allows("http://127.0.0.1:8080/x", portal: "http://127.0.0.1:8080/"))
        #expect(allows("http://[::1]:8080/x", portal: "http://[::1]:8080/"))
    }

    @Test func fragmentAndAtSignTricksAreDenied() {
        #expect(!allows("http://evil.test#@portal.test:4173/"))
        #expect(!allows("https://evil.test/@portal.test:4173/"))
        #expect(!allows("https://evil.test?@portal.test:4173/"))
        #expect(!allows("https://portal.test:4173.evil.test/"))
        #expect(!allows("https://portal.test:4173:80/"))
    }

    @Test func sameOriginOtherPathOrQueryIsAllowed() {
        #expect(allows("https://portal.test:4173/other?x=1"))
        #expect(allows("https://portal.test:4173"))
        #expect(allows("https://portal.test:4173/#/route"))
    }

    @Test func deepLinksAndSystemSchemesAreDeniedInEveryFrame() {
        for url in ["pincer://open?x=1", "mailto:a@b.test", "tel:+15551234", "x-apple-reminderkit://x", "blob:https://portal.test:4173/id",
                    "javascript:void(0)", "data:text/html;base64,PGI+", "file:///Users/x"] {
            #expect(!allows(url, main: true), "\(url)")
            #expect(!allows(url, main: false), "\(url)")
        }
    }

    @Test func externalURLIsWebOnlyWithoutUserinfoOrToken() throws {
        func external(_ s: String) -> String? { URL(string: s).flatMap(PortalOriginPolicy.externalURL(for:))?.absoluteString }
        #expect(external("https://docs.test/a?x=1") == "https://docs.test/a?x=1")
        #expect(external("http://docs.test/a?openclaw_portal=secret") == "http://docs.test/a")
        #expect(external("https://docs.test/a?x=1&openclaw_portal=secret&y=2") == "https://docs.test/a?x=1&y=2")
        #expect(external("https://user:pw@docs.test/") == nil)
        #expect(external("https://user@docs.test/") == nil)
        for url in ["pincer://open", "mailto:a@b.test", "tel:1", "javascript:alert(1)", "file:///x", "data:text/html,x", "about:blank",
                    "ws://docs.test/", "demo-portal://studio-clock/", "x-apple-reminderkit://x"] {
            #expect(external(url) == nil, "\(url)")
        }
    }

    @Test func aRedirectOrOpenerTargetWithTheTokenNeverLeaksIt() {
        let portal = samplePortal()
        let sameOriginLink = URL(string: "https://portal.test:4173/next?openclaw_portal=secret")!
        #expect(PortalOriginPolicy.allows(sameOriginLink, portal: portal))
        #expect(PortalOriginPolicy.externalURL(for: sameOriginLink)?.absoluteString == "https://portal.test:4173/next")
    }

    @Test func eachPortalHasItsOwnOrigin() {
        let a = samplePortal("http://127.0.0.1:4001/")
        let b = samplePortal("http://127.0.0.1:4002/")
        #expect(!PortalOriginPolicy.allows(b.publicURL, portal: a))
        #expect(!PortalOriginPolicy.allows(a.publicURL, portal: b))
    }

    @Test func defaultPortsAreNormalised() {
        #expect(allows("https://portal.test:443/x", portal: "https://portal.test/"))
        #expect(allows("https://portal.test/x", portal: "https://portal.test:443/"))
        #expect(allows("http://portal.test:80/x", portal: "http://portal.test/"))
        #expect(!allows("http://portal.test:443/x", portal: "http://portal.test/"))
        #expect(!allows("https://portal.test:80/x", portal: "https://portal.test/"))
    }

    @Test func hostCaseIsNormalisedButATrailingDotIsDenied() {
        #expect(allows("https://PORTAL.Test:4173/"))
        #expect(allows("HTTPS://Portal.TEST:4173/"))
        #expect(allows("https://portal.test:4173/", portal: "https://Portal.TEST:4173/"))
        #expect(!allows("https://portal.test.:4173/"))
        #expect(!allows("https://portal.test:4173/", portal: "https://portal.test.:4173/"))
        #expect(allows("https://portal.test.:4173/x", portal: "https://portal.test.:4173/"))
    }

    @Test func lookalikeAndUnicodeHostsAreRefused() {
        #expect(!allows("https://portal.test.evil.test:4173/"))
        #expect(!allows("https://portаl.test:4173/")) // Cyrillic "а"
        #expect(!allows("https://xn--portl-cpe.test:4173/"))
    }

    @Test func demoSchemeMatchesItself() {
        let demo = samplePortal("demo-portal://studio-clock/")
        #expect(PortalOriginPolicy.allows(URL(string: "demo-portal://studio-clock/x")!, portal: demo))
        #expect(!PortalOriginPolicy.allows(URL(string: "demo-portal://other/")!, portal: demo))
        #expect(!PortalOriginPolicy.allows(URL(string: "https://studio-clock/")!, portal: demo))
    }

    @Test func tokenIsStrippedForDisplay() throws {
        func stripped(_ s: String) throws -> String { PortalOriginPolicy.strippedForDisplay(try #require(URL(string: s))).absoluteString }
        #expect(try stripped("https://portal.test:4173/?openclaw_portal=secret") == "https://portal.test:4173/")
        #expect(try stripped("https://portal.test:4173/a?x=1&openclaw_portal=secret&y=2") == "https://portal.test:4173/a?x=1&y=2")
        #expect(try stripped("https://portal.test:4173/a?openclaw_portal=one&openclaw_portal=two") == "https://portal.test:4173/a")
        #expect(try stripped("https://portal.test:4173/a?x=1") == "https://portal.test:4173/a?x=1")
        #expect(try stripped("https://portal.test:4173/a") == "https://portal.test:4173/a")
    }
}

/// Answers `portal.list` and `portal.close` by hand and records the calls.
private actor FakePortalGateway {
    var list: [JSONValue]
    private(set) var listCalls = 0
    private(set) var closeCalls: [String] = []
    var closeError: Error?
    var holdClose = false
    private var closeGate: CheckedContinuation<Void, Never>?
    private var closeStarted: CheckedContinuation<Void, Never>?
    private var startedFlag = false

    init(list: [JSONValue]) { self.list = list }

    func setList(_ list: [JSONValue]) { self.list = list }
    func setCloseError(_ error: Error?) { closeError = error }
    func hold() { holdClose = true }

    func release() { holdClose = false; closeGate?.resume(); closeGate = nil }

    func waitForCloseToStart() async {
        if startedFlag { return }
        await withCheckedContinuation { closeStarted = $0 }
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "portal.list":
            listCalls += 1
            return ["portals": .array(list)]
        case "portal.close":
            closeCalls.append(params["id"]?.string ?? "")
            startedFlag = true
            closeStarted?.resume(); closeStarted = nil
            if holdClose { await withCheckedContinuation { closeGate = $0 } }
            if let closeError { throw closeError }
            let id = params["id"]?.string
            list.removeAll { $0["id"]?.string == id }
            return ["closed": true]
        default:
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method", details: nil)
        }
    }
}

private func portalEventually(_ timeout: Double = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + waitDeadline(.seconds(timeout))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
struct PortalStoreTests {
    private func makeStore(_ fake: FakePortalGateway, methods: Set<String>? = nil, debounce: Duration = .milliseconds(40)) -> PortalStore {
        PortalStore(request: { try await fake.request($0, $1) }, methods: { methods }, debounce: debounce)
    }

    private let clock = portalJSON(id: "clock", title: "Clock")
    private let board = portalJSON(id: "board", title: "Board", publicUrl: "https://portal.test:4174/", url: "https://portal.test:4174/?openclaw_portal=t")

    @Test func refreshLoadsThePortals() async {
        let fake = FakePortalGateway(list: [clock, board])
        let store = makeStore(fake)
        await store.refresh()
        #expect(store.portals.map(\.id) == ["clock", "board"])
        #expect(store.loaded && !store.unavailable && !store.redacted)
    }

    @Test func notAdvertisedMeansUnavailableAndNoRequest() async {
        let fake = FakePortalGateway(list: [clock])
        let store = makeStore(fake, methods: ["chat.send"])
        await store.refresh()
        #expect(store.unavailable && store.portals.isEmpty && store.loaded)
        #expect(await fake.listCalls == 0)
    }

    @Test func portalsUnavailableErrorHidesThePortalUI() async {
        let store = PortalStore(request: { _, _ in
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Portals unavailable on this gateway", details: nil)
        }, debounce: .milliseconds(10))
        await store.refresh()
        #expect(store.unavailable)
    }

    @Test func redactedListIsFlagged() async {
        let fake = FakePortalGateway(list: [portalJSON(url: nil)])
        let store = makeStore(fake)
        await store.refresh()
        #expect(store.redacted && store.portals.count == 1 && store.portals[0].loadURL == nil)
    }

    @Test func aBurstOfChangeEventsRefreshesOnce() async {
        let fake = FakePortalGateway(list: [clock])
        let store = makeStore(fake)
        await store.refresh()
        let before = await fake.listCalls
        await fake.setList([clock, board])
        for _ in 0..<10 { store.handle(event: "portal.changed") }
        #expect(await portalEventually { store.portals.count == 2 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await fake.listCalls == before + 1)
    }

    @Test func otherEventsAreIgnored() async {
        let fake = FakePortalGateway(list: [clock])
        let store = makeStore(fake)
        await store.refresh()
        store.handle(event: "chat")
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await fake.listCalls == 1)
    }

    @Test func aRedactedChangeEventKeepsTheLinks() async {
        // The Gateway's event is redacted; the store re-fetches instead of using the payload, so links survive.
        let fake = FakePortalGateway(list: [clock])
        let store = makeStore(fake)
        await store.refresh()
        store.handle(event: "portal.changed")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(store.portals.first?.loadURL != nil && !store.redacted)
    }

    @Test func closeRemovesAtOnceThenConfirms() async {
        let fake = FakePortalGateway(list: [clock, board])
        let store = makeStore(fake)
        await store.refresh()
        await fake.hold()
        let closing = Task { await store.close("clock") }
        await fake.waitForCloseToStart()
        #expect(store.portals.map(\.id) == ["board"])
        await fake.release()
        #expect(await closing.value)
        #expect(store.portals.map(\.id) == ["board"] && store.closeError == nil)
        #expect(await fake.closeCalls == ["clock"])
    }

    @Test func aFailedCloseRestoresThePortalInPlace() async {
        let fake = FakePortalGateway(list: [clock, board])
        let store = makeStore(fake)
        await store.refresh()
        await fake.setCloseError(GatewayError.rpc(code: "UNAVAILABLE", message: "nope", details: nil))
        #expect(await store.close("clock") == false)
        #expect(store.portals.map(\.id) == ["clock", "board"])
        #expect(store.closeError != nil)
    }

    @Test func closeErrorTextHoldsNoURLOrToken() async {
        let fake = FakePortalGateway(list: [clock])
        let store = makeStore(fake)
        await store.refresh()
        await fake.setCloseError(GatewayError.rpc(code: "UNAVAILABLE", message: "failed https://portal.test:4173/?openclaw_portal=secret", details: nil))
        _ = await store.close("clock")
        let text = store.closeError ?? ""
        #expect(!text.contains("secret") && !text.contains("portal.test"))
    }

    @Test func closingAnUnknownPortalDoesNothing() async {
        let fake = FakePortalGateway(list: [clock])
        let store = makeStore(fake)
        await store.refresh()
        #expect(await store.close("ghost") == false)
        #expect(await fake.closeCalls.isEmpty)
    }

    @Test func aChangeEventDuringACloseDoesNotBringTheRowBack() async {
        let fake = FakePortalGateway(list: [clock, board])
        let store = makeStore(fake)
        await store.refresh()
        await fake.hold()
        let closing = Task { await store.close("clock") }
        await fake.waitForCloseToStart()
        store.handle(event: "portal.changed")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(store.portals.map(\.id) == ["board"])
        await fake.release()
        _ = await closing.value
    }

    @Test func reconnectReloads() async {
        let fake = FakePortalGateway(list: [clock])
        let store = makeStore(fake)
        await store.refresh()
        await fake.setList([clock, board])
        store.handleReconnect()
        #expect(await portalEventually { store.portals.count == 2 })
    }
}

struct TLSPinTests {
    private static let certificate = "MIIBfDCCASOgAwIBAgIUfFN8AqzbGQDWE64p+nrTr3CLrbswCgYIKoZIzj0EAwIwEzERMA8GA1UEAwwIcGluLnRlc3QwIBcNMjYxMDE2MTYxNzE3WhgPMjEyNjA5MjIxNjE3MTdaMBMxETAPBgNVBAMMCHBpbi50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKGTLYOofvCsblUu9KjBG9BQIoRkL5hYYbeES6CsClUlMVd984sGuCYfKYBEYG+eTVb+IlVD+k659qbyRa7TLPqNTMFEwHQYDVR0OBBYEFNzH31tv15pOOCNddQrOA4CbYgXfMB8GA1UdIwQYMBaAFNzH31tv15pOOCNddQrOA4CbYgXfMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgJbEn4aYL4N4ke6B+9tsSqg8c6cf8ykEx/bMkqhzgreoCIExJZhFyhrSDqSepjEqlODuc7srHpGjupR9IQxrexnYU"

    private func trust() throws -> SecTrust {
        let der = try #require(Data(base64Encoded: Self.certificate))
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        return try #require(trust)
    }

    private static let fingerprint = "1094ea222aeffb386588227ad74df7d4b5c76ea7b7a2ef20b1ca8fda678f5c3e"

    @Test func theLeafFingerprintMatchesInAnyFormat() throws {
        let trust = try trust()
        #expect(TLSPin.matches(trust, fingerprint: Self.fingerprint))
        #expect(TLSPin.matches(trust, fingerprint: Self.fingerprint.uppercased()))
        let colons = stride(from: 0, to: Self.fingerprint.count, by: 2).map { i -> String in
            let start = Self.fingerprint.index(Self.fingerprint.startIndex, offsetBy: i)
            return String(Self.fingerprint[start..<Self.fingerprint.index(start, offsetBy: 2)])
        }.joined(separator: ":")
        #expect(TLSPin.matches(trust, fingerprint: colons))
    }

    @Test func aWrongOrEmptyFingerprintNeverMatches() throws {
        let trust = try trust()
        #expect(!TLSPin.matches(trust, fingerprint: String(repeating: "0", count: 64)))
        #expect(!TLSPin.matches(trust, fingerprint: ""))
        #expect(!TLSPin.matches(trust, fingerprint: "   "))
        #expect(!TLSPin.matches(trust, fingerprint: "not hex"))
        #expect(!TLSPin.matches(trust, fingerprint: String(Self.fingerprint.dropLast(2))))
    }
}
