import Foundation
import Testing
@testable import PincerKit

@Suite("Handoff gateway matching (#375)")
struct HandoffResolutionTests {
    typealias Candidate = PincerRoute.Candidate

    static let phone = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    static let mac = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
    static let mac2 = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!
    static let demoId = UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000004")!
    static let key = "agent:main:discord:channel:123"

    static func route(url: String? = nil, host: String? = nil, key: String? = Self.key,
                      id: UUID = Self.phone) -> PincerRoute {
        PincerRoute(gateway: .id(id), sessionKey: key, gatewayURL: url, gatewayHost: host)
    }

    static func open(_ id: UUID, _ key: String = Self.key) -> PincerRoute.Resolution {
        .openChat(Notifier.Target(gatewayId: id, sessionKey: key), messageId: nil)
    }

    // MARK: Matching

    @Test func travisCaseMatchesByReportedHost() {
        let candidates = [Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "ws://127.0.0.1:18789",
                                    gatewayHost: "Travis-MBP.local")]
        let route = Self.route(url: "wss://travis-mbp.tail1234.ts.net", host: "travis-mbp.local")
        #expect(route.resolve(in: candidates) == Self.open(Self.mac))
    }

    @Test func olderSenderWithoutHostMatchesByMachineName() {
        let candidates = [Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "ws://travis-mbp.local:18789")]
        let route = Self.route(url: "wss://travis-mbp.tail1234.ts.net")
        #expect(route.gatewayHost == nil)
        #expect(route.resolve(in: candidates) == Self.open(Self.mac))
    }

    @Test func schemelessSenderURLIsSentAndMatches() throws {
        let route = Self.route(url: "travis-mbp.tail1234.ts.net")
        let url = try #require(route.handoffUserInfo[PincerRoute.Key.url])
        #expect(url == "wss://travis-mbp.tail1234.ts.net")
        let received = try #require(PincerRoute(handoffUserInfo: route.handoffUserInfo))
        let candidates = [Candidate(id: Self.mac, isDemo: false, sessionKeys: nil,
                                    url: "wss://travis-mbp.tail1234.ts.net/")]
        #expect(received.resolve(in: candidates) == Self.open(Self.mac))
    }

    @Test func differentSchemeOrDefaultPortStillMatches() {
        let wss = [Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "wss://gw.example.com")]
        // Loose tier: ws on 443 has the same effective address as wss default.
        #expect(Self.route(url: "ws://gw.example.com:443").resolve(in: wss) == Self.open(Self.mac))
        // Different port, same host: only the machine-name tier ("gw") ties them; that's enough.
        let ws = [Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "ws://gw.example.com:18789")]
        #expect(Self.route(url: "wss://gw.example.com").resolve(in: ws) == Self.open(Self.mac))
    }

    @Test func sameMachineGatewaysAreToldApartByExactURL() {
        let a = Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "ws://box.local:18789", gatewayHost: "box.local")
        let b = Candidate(id: Self.mac2, isDemo: false, sessionKeys: nil, url: "ws://box.local:18790", gatewayHost: "box.local")
        let route = Self.route(url: "ws://box.local:18790", host: "box.local")
        #expect(route.resolve(in: [a, b]) == Self.open(Self.mac2))
        #expect(Self.route(url: "ws://box.local:18789", host: "box.local").resolve(in: [b, a]) == Self.open(Self.mac))
    }

    @Test func sameMachineTieFallsToTheGatewayHoldingTheSession() {
        let a = Candidate(id: Self.mac, isDemo: false, sessionKeys: ["agent:main:other"], url: "ws://127.0.0.1:1",
                          gatewayHost: "box.local")
        let b = Candidate(id: Self.mac2, isDemo: false, sessionKeys: [Self.key], url: "ws://127.0.0.1:2",
                          gatewayHost: "box.local")
        let route = Self.route(url: "wss://box.example.com", host: "box.local")
        #expect(route.resolve(in: [a, b]) == Self.open(Self.mac2))
        #expect(route.resolve(in: [b, a]) == Self.open(Self.mac2))
    }

    @Test func preferredIdBreaksRemainingTies() {
        let a = Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "ws://127.0.0.1:1", gatewayHost: "box.local")
        let b = Candidate(id: Self.mac2, isDemo: false, sessionKeys: nil, url: "ws://127.0.0.1:2", gatewayHost: "box.local")
        let route = Self.route(host: "box.local")
        #expect(route.resolve(in: [a, b], preferring: Self.mac2) == Self.open(Self.mac2))
        #expect(route.resolve(in: [a, b]) == Self.open(Self.mac))
    }

    @Test func hostBeatsMachineNameOnlyMatch() {
        let machineOnly = Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "ws://travis-mbp.local:18789")
        let hostMatch = Candidate(id: Self.mac2, isDemo: false, sessionKeys: nil, url: "ws://127.0.0.1:18789",
                                  gatewayHost: "travis-mbp.local")
        let route = Self.route(url: "wss://travis-mbp.tail1234.ts.net", host: "travis-mbp.local")
        #expect(route.resolve(in: [machineOnly, hostMatch]) == Self.open(Self.mac2))
    }

    @Test func exactIdStillWins() {
        let a = Candidate(id: Self.phone, isDemo: false, sessionKeys: nil, url: "ws://other.local:1")
        let b = Candidate(id: Self.mac, isDemo: false, sessionKeys: nil, url: "ws://box.local:1", gatewayHost: "box.local")
        #expect(Self.route(url: "ws://box.local:1", host: "box.local").resolve(in: [b, a]) == Self.open(Self.phone))
    }

    // MARK: Session key fallback

    @Test func singleHolderOfASpecificKeyIsUsedWithoutAddressEvidence() {
        let holder = Candidate(id: Self.mac, isDemo: false, sessionKeys: [Self.key])
        let other = Candidate(id: Self.mac2, isDemo: false, sessionKeys: ["agent:main:other"])
        #expect(Self.route().resolve(in: [other, holder]) == Self.open(Self.mac))
    }

    @Test func twoHoldersOfTheKeyAreAmbiguous() {
        let a = Candidate(id: Self.mac, isDemo: false, sessionKeys: [Self.key])
        let b = Candidate(id: Self.mac2, isDemo: false, sessionKeys: [Self.key])
        #expect(Self.route().resolve(in: [a, b]) == .unknownGateway)
    }

    @Test(arguments: ["main", "global", "unknown", "agent:main:main", "agent:work:main"])
    func genericKeysNeverUseTheFallback(_ key: String) {
        let holder = Candidate(id: Self.mac, isDemo: false, sessionKeys: [key])
        #expect(Self.route(key: key).resolve(in: [holder]) == .unknownGateway)
    }

    @Test func unlistedSessionsDontCountForTheFallback() {
        let unlisted = Candidate(id: Self.mac, isDemo: false, sessionKeys: nil)
        #expect(Self.route().resolve(in: [unlisted]) == .unknownGateway)
    }

    @Test func demoHoldingTheKeyNeverCounts() {
        let demo = Candidate(id: Self.demoId, isDemo: true, sessionKeys: [Self.key])
        #expect(Self.route().resolve(in: [demo]) == .unknownGateway)
        let real = Candidate(id: Self.mac, isDemo: false, sessionKeys: [Self.key])
        #expect(Self.route().resolve(in: [demo, real]) == Self.open(Self.mac))
    }

    @Test func matchedGatewayStillVerifiesTheSession() {
        let candidate = Candidate(id: Self.mac, isDemo: false, sessionKeys: ["agent:main:other"], url: "ws://box.local:1",
                                  gatewayHost: "box.local")
        #expect(Self.route(host: "box.local").resolve(in: [candidate])
            == .unknownSession(gatewayId: Self.mac, sessionKey: Self.key))
    }

    // MARK: Demo

    @Test func demoIsNeverMatchedByHostURLOrMachineName() {
        let demo = Candidate(id: Self.demoId, isDemo: true, sessionKeys: nil, url: "ws://box.local:18789",
                             gatewayHost: "box.local")
        #expect(Self.route(url: "ws://box.local:18789", host: "box.local").resolve(in: [demo]) == .unknownGateway)
        #expect(Self.route(url: "wss://box.example.com").resolve(in: [demo]) == .unknownGateway)
        #expect(Self.route(host: "box.local").resolve(in: [demo]) == .unknownGateway)
    }

    // MARK: Round trips

    @Test func hostRoundTripsThroughURLAndUserInfo() throws {
        let route = Self.route(url: "wss://gw.example.com", host: "  Travis-MBP.Local. ")
        #expect(route.gatewayHost == "travis-mbp.local")
        #expect(route.url.absoluteString.contains("host=travis-mbp.local"))
        #expect(PincerRoute.parse(route.url) == route)
        #expect(PincerRoute.parse(route.url)?.gatewayHost == "travis-mbp.local")
        #expect(route.userInfo[PincerRoute.Key.host] == "travis-mbp.local")
        #expect(route.handoffUserInfo[PincerRoute.Key.host] == "travis-mbp.local")
        #expect(PincerRoute(userInfo: route.userInfo) == route)
        #expect(PincerRoute(handoffUserInfo: route.handoffUserInfo)?.gatewayHost == "travis-mbp.local")
        #expect(PincerRoute.Key.host == "host")
    }

    @Test func demoRoutesDropTheHost() {
        let demo = PincerRoute(target: Notifier.Target(gatewayId: Self.phone, sessionKey: Self.key), isDemo: true,
                               gatewayHost: "box.local")
        #expect(demo.gatewayHost == nil)
        #expect(demo.userInfo[PincerRoute.Key.host] == nil)
        let direct = PincerRoute(gateway: .demo, sessionKey: Self.key, gatewayHost: "box.local")
        #expect(direct.gatewayHost == nil)
    }

    @Test(arguments: ["bad host", "a/b", "", "   ", "host_name", "https://box.local", String(repeating: "a", count: 254)])
    func garbageHostsAreDropped(_ host: String) {
        #expect(PincerRoute.normalizedGatewayHost(host) == nil)
        #expect(Self.route(host: host).gatewayHost == nil)
        #expect(Self.route(host: host).userInfo[PincerRoute.Key.host] == nil)
    }

    @Test func garbageHostInALinkIsIgnored() throws {
        let link = "pincer://open?gateway=\(Self.phone.uuidString)&session=agent:main:main&host=bad%20host"
        let route = try #require(URL(string: link).flatMap(PincerRoute.parse))
        #expect(route.gatewayHost == nil)
    }

    @Test func hostsAreNormalizedAndBounded() {
        #expect(PincerRoute.normalizedGatewayHost("192.168.1.5:18789") == "192.168.1.5:18789")
        #expect(PincerRoute.normalizedGatewayHost("Mac.Local.") == "mac.local")
        #expect(PincerRoute.normalizedGatewayHost(String(repeating: "a", count: 253)) != nil)
    }

    // MARK: Privacy

    @Test func unknownGatewayNoticeLeaksNothingFromTheLink() {
        let route = Self.route(url: "wss://secret-box.tail1234.ts.net", host: "secret-box.local")
        let notice = PincerRoute.Notice.unknownGateway
        #expect(!notice.contains("secret-box"))
        #expect(!notice.contains("tail1234"))
        #expect(!notice.contains(Self.phone.uuidString))
        #expect(route.resolve(in: [Candidate]()) == .unknownGateway)
    }

    // MARK: GatewayHello

    @Test func helloReadsTheGatewaysOwnPresenceHost() {
        let hello = GatewayHello(payload: Fixtures.json("""
        {"snapshot":{"presence":[
          {"host":"Iphone.local","mode":"ui","reason":"connect"},
          {"host":"Travis-MBP.local.","mode":"gateway","reason":"self"},
          {"host":"other.local","mode":"gateway","reason":"connect"}
        ]}}
        """))
        #expect(hello.gatewayHost == "travis-mbp.local")
    }

    @Test func helloWithoutASelfEntryHasNoHost() {
        #expect(GatewayHello(payload: Fixtures.json(#"{"snapshot":{"presence":[{"host":"a.local","mode":"ui","reason":"connect"}]}}"#)).gatewayHost == nil)
        #expect(GatewayHello(payload: Fixtures.json(#"{"snapshot":{}}"#)).gatewayHost == nil)
        #expect(GatewayHello(payload: Fixtures.json("{}")).gatewayHost == nil)
    }

    // MARK: GatewayStore

    @MainActor
    @Test func storeLoadsPersistedHostAndResolvesForeignRoutes() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(id: Self.mac, name: "Mac", url: "ws://127.0.0.1:18789", authMode: .none)
        scratch.defaults.set("travis-mbp.local", forKey: "pincer.gatewayHost.\(Self.mac.uuidString)")
        let store = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        #expect(store.gatewayHost == "travis-mbp.local")
        let route = Self.route(url: "wss://travis-mbp.tail1234.ts.net", host: "travis-mbp.local")
        #expect(route.resolve(in: [store], verifySession: false) == Self.open(Self.mac))
    }

    @MainActor
    @Test func storeWithoutPersistedHostHasNone() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(id: Self.mac, name: "Mac", url: "ws://127.0.0.1:18789", authMode: .none)
        let store = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        #expect(store.gatewayHost == nil)
    }

    // MARK: Tables

    @Test(arguments: [
        ("Travis-MBP.local", "travis-mbp"),
        ("travis-mbp.tail1234.ts.net", "travis-mbp"),
        ("travis-mbp", "travis-mbp"),
        ("192.168.1.5", "192.168.1.5"),
    ] as [(String, String)])
    func machineNames(_ host: String, _ expected: String) {
        #expect(PincerRoute.machineName(host) == expected)
    }

    @Test(arguments: ["localhost", "127.0.0.1", "127.1.2.3", "::1", ""])
    func loopbackAndEmptyHaveNoMachineName(_ host: String) {
        #expect(PincerRoute.machineName(host) == nil)
    }

    @Test(arguments: [
        ("travis-mbp.tail1234.ts.net", "wss://travis-mbp.tail1234.ts.net"),
        ("192.168.1.5:18789", "ws://192.168.1.5:18789"),
        ("ws://mac.local.:18789", "ws://mac.local:18789"),
        ("WSS://GW.Example.com:443/", "wss://gw.example.com"),
        ("ws://user:pw@gw.example.com:80?x=1#f", "ws://gw.example.com"),
    ] as [(String, String)])
    func normalizesURLs(_ input: String, _ expected: String) {
        #expect(PincerRoute.normalizedGatewayURL(input) == expected)
    }
}
