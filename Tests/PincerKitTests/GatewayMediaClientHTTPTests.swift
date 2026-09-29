import Foundation
import Testing
@testable import PincerKit

/// Serves canned responses to the media client's URLSession, so HTTP behaviour runs in-process.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.lock.lock()
        self.handler = handler
        self.requests = []
        self.lock.unlock()
    }

    static var seen: [URLRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(self.request)
        let handler = Self.handler
        Self.lock.unlock()
        let reply = handler?(self.request) ?? Reply(status: 404)
        let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { self.client?.urlProtocol(self, didLoad: chunk) }
        self.client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
@Suite("GatewayMediaClient HTTP", .serialized)
struct GatewayMediaClientHTTPTests {
    static let gateway = URL(string: "https://gw.media-stub.test/media/a.png")!
    static let publicURL = URL(string: "https://cdn.example.com/a.png")!

    static func client(secrets: @escaping () -> String? = { "tok" }, maxBytes: Int = 1000) -> GatewayMediaClient {
        let profile = GatewayProfile(name: "Stub", url: "wss://gw.media-stub.test", authMode: .token)
        let client = GatewayMediaClient(profile: { profile }, maxBytes: maxBytes, secretReader: { _ in secrets() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client.configurationOverride = configuration
        return client
    }

    nonisolated static func header(_ request: URLRequest) -> String? { request.value(forHTTPHeaderField: "Authorization") }

    @Test func bearerGoesToTheGatewayOnly() async throws {
        StubURLProtocol.reset { _ in .init(chunks: [Data("ok".utf8)]) }
        let client = Self.client()
        let fromGateway = try await client.fetchGateway(Self.gateway)
        let fromWeb = try await client.fetchPublic(Self.publicURL, accept: "image/*")
        #expect(fromGateway == Data("ok".utf8) && fromWeb == Data("ok".utf8))
        let seen = StubURLProtocol.seen
        let gatewayRequest = try #require(seen.first { $0.url?.host == "gw.media-stub.test" })
        let publicRequest = try #require(seen.first { $0.url?.host == "cdn.example.com" })
        #expect(Self.header(gatewayRequest) == "Bearer tok")
        #expect(Self.header(publicRequest) == nil)
    }

    @Test func unauthorizedRereadsCredentialsAndRetriesOnce() async throws {
        StubURLProtocol.reset { request in
            Self.header(request) == "Bearer new" ? .init(chunks: [Data("ok".utf8)]) : .init(status: 401)
        }
        var reads = 0
        let client = Self.client(secrets: { reads += 1; return reads == 1 ? "old" : "new" })
        let data = try await client.fetchGateway(Self.gateway)
        #expect(data == Data("ok".utf8))
        #expect(client.keychainReads == 2)
        #expect(StubURLProtocol.seen.count == 2)
    }

    @Test func persistentUnauthorizedDoesNotLoop() async throws {
        StubURLProtocol.reset { _ in .init(status: 403) }
        let client = Self.client()
        let data = try await client.fetchGateway(Self.gateway)
        #expect(data == nil)
        #expect(StubURLProtocol.seen.count == 2)
        #expect(client.keychainReads == 2)
    }

    @Test func concurrentUnauthorizedResponsesDoNotStormTheKeychain() async throws {
        StubURLProtocol.reset { request in
            Self.header(request) == "Bearer new" ? .init(chunks: [Data("ok".utf8)]) : .init(status: 401)
        }
        var reads = 0
        let client = Self.client(secrets: { reads += 1; return reads == 1 ? "old" : "new" })
        let fetches = (0..<8).map { _ in Task { @MainActor in try? await client.fetchGateway(Self.gateway) } }
        var results: [Data?] = []
        for fetch in fetches { results.append(await fetch.value ?? nil) }
        #expect(results.allSatisfy { $0 == Data("ok".utf8) })
        // At most one re-read per session generation, never one per failed request.
        #expect(client.keychainReads <= 3)
    }

    @Test func declaredContentLengthOverTheCapIsTooLarge() async {
        StubURLProtocol.reset { _ in .init(headers: ["Content-Length": "5000"], chunks: [Data(count: 10)]) }
        let client = Self.client()
        await #expect(throws: MediaError.self) { _ = try await client.fetchGateway(Self.gateway) }
        await #expect(throws: MediaError.self) { _ = try await client.fetchPublic(Self.publicURL, accept: "image/*") }
    }

    @Test func streamedBodyOverTheCapIsTooLarge() async {
        StubURLProtocol.reset { _ in .init(chunks: (0..<10).map { _ in Data(count: 300) }) }
        let client = Self.client()
        await #expect(throws: MediaError.self) { _ = try await client.fetchGateway(Self.gateway) }
        await #expect(throws: MediaError.self) { _ = try await client.fetchPublic(Self.publicURL, accept: "image/*") }
    }

    @Test func explicitLimitAllowsWhatTheDefaultRejects() async throws {
        StubURLProtocol.reset { _ in .init(chunks: [Data(count: 5000)]) }
        let client = Self.client()
        let data = try await client.fetchGateway(Self.gateway, maxBytes: 10_000)
        #expect(data?.count == 5000)
    }

    @Test func resetDuringFetchesDoesNotCrash() async {
        StubURLProtocol.reset { _ in .init(chunks: [Data("ok".utf8)]) }
        let client = Self.client()
        let fetches = (0..<20).map { _ in Task { @MainActor in try? await client.fetchGateway(Self.gateway) } }
        for _ in 0..<20 {
            client.reset()
            await Task.yield()
        }
        for fetch in fetches { _ = await fetch.value }
        #expect(client.sessionsCreated >= 1)
    }
}
