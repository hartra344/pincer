import Foundation
import Testing
@testable import PincerKit

@Suite("Deep links & Handoff")
struct DeepLinkTests {
    static let gateway = UUID(uuidString: "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")!
    static let other = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func parse(_ text: String) -> PincerRoute? {
        URL(string: text).flatMap(PincerRoute.parse)
    }

    static func route(_ key: String?, message: String? = nil, gateway: UUID = Self.gateway) -> PincerRoute {
        PincerRoute(gateway: .id(gateway), sessionKey: key, messageId: message)
    }

    static func target(_ key: String, gateway: UUID = Self.gateway) -> Notifier.Target {
        Notifier.Target(gatewayId: gateway, sessionKey: key)
    }

    // MARK: Parsing

    @Test func parsesAMinimalLink() throws {
        let route = try #require(Self.parse("pincer://open?gateway=\(Self.gateway.uuidString)&session=agent:main:main"))
        #expect(route == Self.route("agent:main:main"))
        #expect(route.messageId == nil)
    }

    @Test func acceptsALowercaseUUIDAndScheme() throws {
        #expect(Self.parse("pincer://open?gateway=\(Self.gateway.uuidString.lowercased())&session=agent:main:main")
            == Self.route("agent:main:main"))
        #expect(Self.parse("PINCER://open?gateway=\(Self.gateway.uuidString)&session=agent:main:main")
            == Self.route("agent:main:main"))
    }

    @Test func parsesTheMessageParameter() throws {
        let route = try #require(Self.parse(
            "pincer://open?gateway=\(Self.gateway.uuidString)&session=agent%3Amain%3Amain&message=demo-main-status"))
        #expect(route == Self.route("agent:main:main", message: "demo-main-status"))
    }

    @Test func emptyMessageIsNoMessage() throws {
        let route = try #require(Self.parse("pincer://open?gateway=\(Self.gateway.uuidString)&session=agent:main:main&message="))
        #expect(route.messageId == nil)
    }

    @Test func missingOrEmptySessionOpensTheGateway() throws {
        #expect(Self.parse("pincer://open?gateway=\(Self.gateway.uuidString)") == Self.route(nil))
        #expect(Self.parse("pincer://open?gateway=\(Self.gateway.uuidString)&session=") == Self.route(nil))
    }

    @Test func demoLinksNameTheDemo() throws {
        let route = try #require(Self.parse("pincer://open?gateway=demo&session=agent:main:main"))
        #expect(route.gateway == .demo && route.sessionKey == "agent:main:main")
        #expect(Self.parse("pincer://open?gateway=DEMO&session=agent:main:main")?.gateway == .demo)
        let built = PincerRoute(target: Self.target("agent:main:main"), isDemo: true, messageId: "demo-main-status")
        #expect(built.gateway == .demo && built.url.absoluteString.contains("gateway=demo"))
        #expect(PincerRoute.parse(built.url) == built)
    }

    @Test func ignoresUnknownParameters() throws {
        let route = try #require(Self.parse(
            "pincer://open?utm=x&gateway=\(Self.gateway.uuidString)&send=hello&session=agent:main:main&approve=allow-once&decision=allow-always"))
        #expect(route == Self.route("agent:main:main"))
    }

    @Test(arguments: [
        "https://open?gateway=0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9&session=agent:main:main",
        "openclaw://open?gateway=0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9&session=agent:main:main",
        "pincer://send?gateway=0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9&session=agent:main:main",
        "pincer://approve?gateway=0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9&session=agent:main:main",
        "pincer://?gateway=0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9&session=agent:main:main",
        "pincer://open?session=agent:main:main",
        "pincer://open?gateway=not-a-uuid&session=agent:main:main",
        "pincer://open?gateway=0A1B2C3D-4E5F-4071-8293&session=agent:main:main",
        "pincer://open?gateway=&session=agent:main:main",
        "pincer://open",
    ])
    func rejectsMalformedLinks(_ text: String) {
        #expect(Self.parse(text) == nil, "\(text)")
        #expect(URL(string: text).flatMap(PincerRoute.init(url:)) == nil, "\(text)")
    }

    // MARK: Building

    @Test func buildsTheDocumentedShape() throws {
        let url = Self.route("agent:main:main").url
        #expect(url.scheme == "pincer")
        #expect(url.host() == "open")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "gateway" }?.value == Self.gateway.uuidString)
        #expect(items.first { $0.name == "session" }?.value == "agent:main:main")
        #expect(!items.contains { $0.name == "message" })
        #expect(PincerRoute.url(for: Self.route("agent:main:main")) == url)
    }

    @Test(arguments: [
        "agent:main:main",
        "agent:main:discord:channel:123",
        "agent:main:dashboard:trip",
        "agent:research:subagent:abc",
        "agent:main:slack:channel:C01/thread:1700000000.1234",
        "agent:main:weird key&with=reserved+chars#and?more%25",
        "agent:main:émoji-🦞",
    ])
    func roundTripsOddSessionKeys(_ key: String) throws {
        for message in [nil, "demo-main-status", "id with/slash&amp=1"] as [String?] {
            let route = Self.route(key, message: message)
            let url = route.url
            let query = url.query(percentEncoded: true) ?? ""
            #expect(!query.contains("/") && !query.contains(":"), "':' and '/' are percent-encoded: \(url.absoluteString)")
            #expect(!query.contains("#") && !query.contains("+") && !query.contains(" ") && !query.contains("?"),
                    "\(url.absoluteString)")
            #expect(query.components(separatedBy: "&").count == (message == nil ? 2 : 3), "\(url.absoluteString)")
            #expect(PincerRoute.parse(url) == route, "\(key) / \(message ?? "nil")")
            #expect(Self.parse(url.absoluteString) == route, "survives a string round-trip: \(url.absoluteString)")
        }
    }

    @Test func routeForAGatewayOnlyRoundTrips() {
        let route = Self.route(nil)
        #expect(!route.url.absoluteString.contains("session="))
        #expect(PincerRoute.parse(route.url) == route)
    }

    // MARK: Handoff

    @Test func userInfoRoundTrips() throws {
        for route in [Self.route("agent:main:slack:C01/thread:1"), Self.route("agent:main:main", message: "demo-lab-sensor"),
                      Self.route(nil), PincerRoute(gateway: .demo, sessionKey: "agent:main:main")]
        {
            #expect(PincerRoute(userInfo: route.userInfo) == route)
        }
    }

    @Test func userInfoIsPropertyListSafe() throws {
        let route = Self.route("agent:main:main", message: "m1")
        // NSUserActivity only carries plist types across devices.
        let data = try PropertyListSerialization.data(fromPropertyList: route.userInfo, format: .binary, options: 0)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [AnyHashable: Any])
        #expect(PincerRoute(userInfo: back) == route)
    }

    @Test func malformedUserInfoIsRejected() {
        #expect(PincerRoute(userInfo: nil) == nil)
        #expect(PincerRoute(userInfo: [:]) == nil)
        #expect(PincerRoute(userInfo: ["gateway": "nope", "session": "agent:main:main"]) == nil)
        #expect(PincerRoute(userInfo: ["gateway": 42, "session": ["x"]]) == nil)
        #expect(PincerRoute(userInfo: ["session": "agent:main:main"]) == nil)
    }

    @Test func activityTypeIsStable() {
        #expect(PincerRoute.activityType == "chat.pincer.chat")
    }

    @Test func matchesAppIntentIds() throws {
        let key = "agent:main:discord:channel:123"
        let parsed = try #require(IntentID.parse(IntentID.scoped(Self.gateway, key)))
        #expect(PincerRoute(target: Self.target(key)) == PincerRoute(gateway: .id(parsed.gatewayId), sessionKey: parsed.local))
    }

    // MARK: Resolving

    static let home = PincerRoute.Candidate(id: Self.gateway, isDemo: false,
                                            sessionKeys: ["agent:main:main", "agent:main:discord:channel:123"])
    static let demo = PincerRoute.Candidate(id: Self.other, isDemo: true, sessionKeys: ["agent:main:main"])

    @Test func resolvesAKnownChat() {
        #expect(Self.route("agent:main:discord:channel:123", message: "m1").resolve(in: [Self.demo, Self.home])
            == .openChat(Self.target("agent:main:discord:channel:123"), messageId: "m1"))
    }

    @Test func resolvesUnknownGatewayAndSession() {
        #expect(Self.route("agent:main:main").resolve(in: [PincerRoute.Candidate]()) == .unknownGateway)
        #expect(Self.route("agent:main:main", gateway: UUID()).resolve(in: [Self.home, Self.demo]) == .unknownGateway)
        #expect(Self.route("agent:main:nope").resolve(in: [Self.home])
            == .unknownSession(gatewayId: Self.gateway, sessionKey: "agent:main:nope"))
        #expect(Self.route(nil).resolve(in: [Self.home]) == .openGateway(Self.gateway))
    }

    @Test func trustsAnyKeyBeforeSessionsAreListed() {
        let unlisted = PincerRoute.Candidate(id: Self.gateway, isDemo: false, sessionKeys: nil)
        #expect(Self.route("agent:main:anything").resolve(in: [unlisted])
            == .openChat(Self.target("agent:main:anything"), messageId: nil))
    }

    @Test func appliesKeyAliases() {
        let route = Self.route("agent:main:alias")
        #expect(route.resolve(in: [Self.home]) { _, _ in "agent:main:main" } == .openChat(Self.target("agent:main:main"), messageId: nil))
    }

    @Test func resolvesDemoLinks() {
        let route = PincerRoute(gateway: .demo, sessionKey: "agent:main:main", messageId: "demo-main-status")
        #expect(route.resolve(in: [Self.home, Self.demo])
            == .openChat(Self.target("agent:main:main", gateway: Self.other), messageId: "demo-main-status"))
        #expect(route.resolve(in: [Self.home]) == .openDemo(sessionKey: "agent:main:main", messageId: "demo-main-status"))
        // A real UUID never falls back to the demo.
        #expect(Self.route("agent:main:main", gateway: UUID()).resolve(in: [Self.demo]) == .unknownGateway)
    }

    @MainActor @Test func resolvesAgainstStores() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(id: Self.gateway, name: "Home", url: "ws://127.0.0.1:18789", authMode: .token)
        let store = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        #expect(Self.route("agent:main:main", gateway: UUID()).resolve(in: [store]) == .unknownGateway)
        #expect(Self.route("agent:main:main").resolve(in: [store]) == .openChat(Self.target("agent:main:main"), messageId: nil))
    }
    // MARK: Acceptance criteria

    @Test func acceptsTheHostlessForm() {
        #expect(Self.parse("pincer:open?gateway=\(Self.gateway.uuidString)&session=agent:main:main") == Self.route("agent:main:main"))
    }

    @Test func noticesUseTheAgreedCopy() {
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{2019}", with: "'") }
        #expect(plain(PincerRoute.Notice.unknownGateway) == "That link points to a Gateway that isn't set up on this device.")
        #expect(plain(PincerRoute.Notice.unknownSession) == "That chat isn't available on this Gateway anymore.")
        #expect(plain(PincerRoute.Notice.unknownMessage) == "Couldn't find that message.")
        #expect(PincerRoute.Notice.linkCopied == "Link copied")
    }

    @Test func handoffCarriesNoMessage() throws {
        let route = Self.route("agent:main:main", message: "m1")
        #expect(route.handoffUserInfo[PincerRoute.Key.message] == nil)
        #expect(Set(route.handoffUserInfo.keys).isSubset(of: [PincerRoute.Key.gateway, PincerRoute.Key.session, PincerRoute.Key.url]))
        let received = try #require(PincerRoute(handoffUserInfo: route.userInfo))
        #expect(received.messageId == nil && received.sessionKey == "agent:main:main" && received.gateway == .id(Self.gateway))
        #expect(PincerRoute(handoffUserInfo: nil) == nil)
    }

    @Test func linksAndHandoffCarryNoCredentials() {
        let raw = "wss://operator:hunter2@Home.Example.com:443/gw/?token=s3cret&password=pw#frag"
        #expect(PincerRoute.normalizedGatewayURL(raw) == "wss://home.example.com/gw")
        #expect(PincerRoute.normalizedGatewayURL("ws://127.0.0.1:18789") == "ws://127.0.0.1:18789")
        #expect(PincerRoute.normalizedGatewayURL("demo://pincer") == nil)
        let route = PincerRoute(gateway: .id(Self.gateway), sessionKey: "agent:main:main", gatewayURL: raw)
        let everything = route.url.absoluteString + route.userInfo.values.joined() + route.handoffUserInfo.values.joined()
        for secret in ["hunter2", "operator", "s3cret", "token", "password", "frag"] {
            #expect(!everything.contains(secret), "\(secret) leaked: \(everything)")
        }
        #expect(PincerRoute(gateway: .demo, sessionKey: "agent:main:main", gatewayURL: "ws://127.0.0.1:1").gatewayURL == nil)
    }

    @Test func ignoresCredentialAndActionParameters() throws {
        let route = try #require(Self.parse("pincer://open?gateway=\(Self.gateway.uuidString)&session=agent:main:main"
            + "&text=hello&token=abc&approve=allow-always&deny=1&decision=allow-once&secret=x&password=y"))
        #expect(route == Self.route("agent:main:main"))
        #expect(!route.url.absoluteString.contains("abc") && !route.url.absoluteString.contains("hello"))
    }

    @Test func intentIdsRoundTrip() throws {
        let id = IntentID.scoped(Self.gateway, "agent:main:slack:C01/thread:1")
        let route = try #require(PincerRoute(intentId: id))
        #expect(route == Self.route("agent:main:slack:C01/thread:1") && route.intentId == id)
        #expect(Self.route(nil).intentId == nil && PincerRoute(gateway: .demo, sessionKey: "agent:main:main").intentId == nil)
        #expect(PincerRoute(intentId: "not-a-uuid/agent:main:main") == nil)
    }

    @Test func findsTheSameGatewayOnAnotherDeviceByAddress() {
        let local = PincerRoute.Candidate(id: Self.other, isDemo: false, sessionKeys: ["agent:main:main"], url: "ws://127.0.0.1:18789/")
        let twin = PincerRoute.Candidate(id: UUID(), isDemo: false, sessionKeys: ["agent:main:main"], url: "ws://127.0.0.1:18789")
        let route = PincerRoute(gateway: .id(Self.gateway), sessionKey: "agent:main:main", gatewayURL: "ws://127.0.0.1:18789")
        #expect(route.resolve(in: [local]) == .openChat(Self.target("agent:main:main", gateway: Self.other), messageId: nil))
        #expect(route.resolve(in: [twin, local], preferring: Self.other)
            == .openChat(Self.target("agent:main:main", gateway: Self.other), messageId: nil))
        #expect(Self.route("agent:main:main").resolve(in: [local]) == .unknownGateway, "no address, no match")
        let demoAtAddress = PincerRoute.Candidate(id: UUID(), isDemo: true, sessionKeys: nil, url: "ws://127.0.0.1:18789")
        #expect(route.resolve(in: [demoAtAddress]) == .unknownGateway, "an address never matches the demo")
    }

    @Test func routesPincerMadeSkipSessionVerification() {
        #expect(Self.route("agent:main:new").resolve(in: [Self.home], verifySession: false)
            == .openChat(Self.target("agent:main:new"), messageId: nil))
        #expect(Self.route("agent:main:new").resolve(in: [Self.home])
            == .unknownSession(gatewayId: Self.gateway, sessionKey: "agent:main:new"))
    }
}
