import Foundation
import Testing
@testable import PincerKit

/// One Keychain read and one URLSession per Gateway (#199 item 7). The secret reader is injected, so
/// nothing here touches the Keychain. HTTP status handling (401 retry, size cap) would need a URLSession-configuration
/// seam on the client, so it isn't covered here.
@MainActor
@Suite("GatewayMediaClient", .serialized)
struct GatewayMediaClientTests {
    static func profile(host: String = "gw.media-stub.test", fingerprint: String? = nil, id: UUID = UUID()) -> GatewayProfile {
        GatewayProfile(id: id, name: "Stub", url: "wss://\(host)", authMode: .token, tlsFingerprint: fingerprint)
    }

    /// A `file:` URL: the client's real ephemeral session serves it in-process, with no socket. The response
    /// isn't HTTP so the fetch returns nil; what matters is the credential and session accounting.
    static let local = URL(fileURLWithPath: "/dev/null")

    static func url(_ path: String = "/a.png", host: String = "gw.media-stub.test") -> URL { local }

    @Test func manyRequestsShareOneKeychainReadAndOneSession() async throws {
                let profile = Self.profile()
        var reads = 0
        let client = GatewayMediaClient(profile: { profile }, secretReader: { _ in reads += 1; return "secret" })
        for i in 0..<12 { _ = try await client.fetchGateway(Self.url("/img\(i).png")) }
        #expect(client.keychainReads == 1)
        #expect(reads == 1)
        #expect(client.sessionsCreated == 1)
    }

    @Test func nothingIsReadBeforeFirstUse() {
        let profile = Self.profile()
        let client = GatewayMediaClient(profile: { profile }, secretReader: { _ in "x" })
        #expect(client.keychainReads == 0 && client.sessionsCreated == 0)
    }

    @Test func resetDropsCredentialsAndSession() async throws {
                let profile = Self.profile()
        let client = GatewayMediaClient(profile: { profile }, secretReader: { _ in "secret" })
        _ = try await client.fetchGateway(Self.url())
        client.reset()
        _ = try await client.fetchGateway(Self.url())
        _ = try await client.fetchGateway(Self.url("/b.png"))
        #expect(client.keychainReads == 2)
        #expect(client.sessionsCreated == 2)
    }

    @Test func rebuiltWhenTheProfileIdentityChanges() async throws {
                var profile = Self.profile(fingerprint: "AA:BB")
        let client = GatewayMediaClient(profile: { profile }, secretReader: { _ in "secret" })
        _ = try await client.fetchGateway(Self.url())
        #expect((client.keychainReads, client.sessionsCreated) == (1, 1))

        // A new pin, host, port or profile id each rebuild; an unrelated edit (name) does not.
        profile.name = "Renamed"
        _ = try await client.fetchGateway(Self.url())
        #expect((client.keychainReads, client.sessionsCreated) == (1, 1))

        profile.tlsFingerprint = "CC:DD"
        _ = try await client.fetchGateway(Self.url())
        #expect((client.keychainReads, client.sessionsCreated) == (2, 2))

        profile.url = "wss://other.media-stub.test"
        _ = try await client.fetchGateway(Self.url(host: "other.media-stub.test"))
        #expect((client.keychainReads, client.sessionsCreated) == (3, 3))

        profile.url = "wss://other.media-stub.test:8443"
        _ = try await client.fetchGateway(Self.url(host: "other.media-stub.test"))
        #expect((client.keychainReads, client.sessionsCreated) == (4, 4))

        profile.id = UUID()
        _ = try await client.fetchGateway(Self.url(host: "other.media-stub.test"))
        #expect((client.keychainReads, client.sessionsCreated) == (5, 5))
    }

    @Test func resetWhileRequestsAreInFlightNeverTouchesAnInvalidatedSession() async throws {
        let profile = Self.profile()
        let client = GatewayMediaClient(profile: { profile }, secretReader: { _ in "secret" })
        let fetches = (0..<30).map { _ in Task { @MainActor in _ = try? await client.fetchGateway(Self.url()) } }
        for _ in 0..<30 {
            client.reset()
            await Task.yield()
        }
        for fetch in fetches { await fetch.value }
        #expect(client.sessionsCreated >= 1)
    }
}
