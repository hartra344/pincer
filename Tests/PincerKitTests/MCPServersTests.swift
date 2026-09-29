import Foundation
import Testing
@testable import PincerKit

private let sentinel = "__OPENCLAW_REDACTED__"

private func server(_ name: String, _ json: String) -> MCPServer? {
    MCPServer(name: name, json: Fixtures.json(json))
}

@Suite("MCP servers: parsing")
struct MCPServerParsingTests {
    @Test func stdioServer() throws {
        let s = try #require(server("fs", #"{"command":"npx","args":["-y","pkg"],"cwd":"/x","env":{"LOG_LEVEL":"info","TOKEN":"\#(sentinel)"}}"#))
        #expect(s.transport == .stdio && s.enabled && s.command == "npx" && s.args == ["-y", "pkg"] && s.cwd == "/x")
        #expect(s.env.count == 2)
        #expect(s.env.first { $0.key == "TOKEN" }?.isRedacted == true)
        #expect(s.env.first { $0.key == "LOG_LEVEL" }?.isRedacted == false)
        #expect(!s.usesOAuth && !s.urlIsRedacted)
    }

    @Test func urlWithoutTransportIsSSE() throws {
        let s = try #require(server("a", #"{"url":"https://x.dev/sse"}"#))
        #expect(s.transport == .sse && s.url == "https://x.dev/sse")
    }

    @Test func explicitTransportWins() throws {
        let s = try #require(server("a", #"{"url":"https://x.dev/mcp","transport":"streamable-http"}"#))
        #expect(s.transport == .streamableHTTP)
    }

    @Test func commandBeatsUrl() throws {
        let s = try #require(server("a", #"{"command":"x","url":"https://x.dev"}"#))
        #expect(s.transport == .stdio)
    }

    @Test func neitherCommandNorUrlIsInvalid() {
        // Either no server at all or a server with no transport; both mean "invalid".
        let s = server("a", #"{"enabled":true}"#)
        #expect(s == nil || s?.transport == nil)
    }

    @Test func enabledDefaultsToTrue() throws {
        #expect(try #require(server("a", #"{"command":"x"}"#)).enabled)
        #expect(try #require(server("a", #"{"command":"x","enabled":false}"#)).enabled == false)
    }

    @Test func redactedHeadersAndUrl() throws {
        let s = try #require(server("gh", #"{"url":"\#(sentinel)","transport":"streamable-http","headers":{"Authorization":"\#(sentinel)","X-A":"b"}}"#))
        #expect(s.urlIsRedacted)
        #expect(s.headers.first { $0.key == "Authorization" }?.isRedacted == true)
        #expect(s.headers.first { $0.key == "X-A" }?.isRedacted == false)
    }

    @Test func oauthAndUnknownKeys() throws {
        let s = try #require(server("l", #"{"url":"https://l.app/mcp","transport":"streamable-http","auth":"oauth","oauth":{"identity":"per-requester"},"futureKey":{"a":1}}"#))
        #expect(s.usesOAuth && s.oauthIdentity == "per-requester")
        #expect(s.raw["futureKey"]?["a"]?.int == 1)
    }

    @Test func serversInConfigSortedByName() {
        let config = Fixtures.json(#"{"mcp":{"servers":{"zeta":{"command":"z"},"Alpha":{"command":"a"},"beta":{"url":"https://b.dev"}}}}"#)
        #expect(MCPServers.servers(in: config).map(\.name) == ["Alpha", "beta", "zeta"])
        #expect(MCPServers.servers(in: nil).isEmpty)
        #expect(MCPServers.servers(in: Fixtures.json(#"{"mcp":{}}"#)).isEmpty)
    }

    @Test func transportBasics() {
        #expect(MCPTransport.streamableHTTP.rawValue == "streamable-http")
        #expect(MCPTransport.streamableHTTP.title == "Streamable HTTP" && MCPTransport.sse.title == "SSE" && MCPTransport.stdio.title == "stdio")
        #expect(!MCPTransport.stdio.isRemote && MCPTransport.sse.isRemote && MCPTransport.streamableHTTP.isRemote)
    }
}

@Suite("MCP servers: masking and names")
struct MCPServerMaskingTests {
    @Test func maskedArgsHidesFlagValues() {
        let masked = MCPServers_maskedArgs(["--url", "http://h", "--token", "abc123", "--api-key", "k", "--password", "p", "--secret", "s", "--dsn", "postgres://u:p@h/db"])
        #expect(masked == ["--url", "http://h", "--token", "••••", "--api-key", "••••", "--password", "••••", "--secret", "••••", "--dsn", "••••"])
    }

    @Test func maskedArgsHidesKeyValueSecrets() {
        let masked = MCPServers_maskedArgs(["API_TOKEN=abc", "user=bob", "db_password=x", "secretKey=1"])
        #expect(masked == ["API_TOKEN=••••", "user=bob", "db_password=••••", "secretKey=••••"])
    }

    @Test func maskedArgsLeavesPlainArgs() {
        #expect(MCPServers_maskedArgs(["-y", "@modelcontextprotocol/server-filesystem", "/Users/x"]) == ["-y", "@modelcontextprotocol/server-filesystem", "/Users/x"])
        #expect(MCPServers_maskedArgs(["--token"]) == ["--token"])
    }

    @Test func launchSummaryStdio() throws {
        let s = try #require(server("f", #"{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","~/Projects"]}"#))
        #expect(s.launchSummary == "npx -y @modelcontextprotocol/server-filesystem ~/Projects")
        let ha = try #require(server("ha", #"{"command":"uvx","args":["mcp-server-home-assistant","--token","secret-value"]}"#))
        #expect(!ha.launchSummary.contains("secret-value") && ha.launchSummary.contains("••••"))
    }

    @Test func launchSummaryRemoteShowsHostAndPath() throws {
        let s = try #require(server("l", #"{"url":"https://mcp.linear.app/mcp","transport":"streamable-http"}"#))
        #expect(s.launchSummary.contains("mcp.linear.app/mcp"))
    }

    @Test func validNames() {
        for ok in ["filesystem", "a", "A1", "home-assistant", "my.server_2", "0abc"] { #expect(MCPServers.isValidName(ok), "\(ok)") }
        for bad in ["", "__proto__", ".hidden", "-dash", "_under", "has space", "slash/name", "émoji", "a$b"] {
            #expect(!MCPServers.isValidName(bad), "\(bad)")
        }
    }

    @Test func returnURL() {
        let url = MCPServers.returnURL(server: "linear")
        #expect(url.scheme == MCPServers.returnURLScheme && url.host == "mcp-oauth" && url.absoluteString.contains("server=linear"))
    }
}

private func MCPServers_maskedArgs(_ args: [String]) -> [String] { MCPServer.maskedArgs(args) }

@Suite("MCP servers: draft")
struct MCPServerDraftTests {
    private func original() throws -> MCPServer {
        try #require(server("gh", #"{"url":"https://api.x/mcp","transport":"streamable-http","headers":{"Authorization":"\#(sentinel)","X":"1"},"futureKey":true,"toolFilter":{"include":["a"]}}"#))
    }

    @Test func newDraftDefaults() {
        let d = MCPServerDraft()
        #expect(d.originalName == nil && d.transport == .stdio && d.enabled && !d.isRename)
    }

    @Test func untouchedRoundTripKeepsUnknownKeysAndSentinel() throws {
        let o = try original()
        let json = MCPServerDraft(server: o).json(original: o)
        #expect(json["futureKey"]?.bool == true)
        #expect(json["toolFilter"]?["include"]?[0]?.string == "a")
        #expect(json["headers"]?["Authorization"]?.string == sentinel)
        #expect(json["headers"]?["X"]?.string == "1")
        #expect(json["url"]?.string == "https://api.x/mcp")
        #expect(json["command"] == nil)
    }

    @Test func editingOneFieldKeepsTheRest() throws {
        let o = try original()
        var d = MCPServerDraft(server: o)
        d.url = "https://api.x/v2"
        let json = d.json(original: o)
        #expect(json["url"]?.string == "https://api.x/v2" && json["futureKey"]?.bool == true)
        #expect(json["headers"]?["Authorization"]?.string == sentinel)
    }

    @Test func switchingTransportDropsOtherTransportKeys() throws {
        let o = try original()
        var d = MCPServerDraft(server: o)
        d.transport = .stdio
        d.command = "npx"
        d.args = ["-y", "x"]
        let json = d.json(original: o)
        #expect(json["command"]?.string == "npx" && json["args"]?[0]?.string == "-y")
        #expect(json["url"] == nil && json["headers"] == nil && json["transport"] == nil || json["transport"]?.string == "stdio")
        #expect(json["futureKey"]?.bool == true)
    }

    @Test func stdioToRemoteDropsCommandKeys() throws {
        let o = try #require(server("f", #"{"command":"npx","args":["a"],"cwd":"/x","env":{"A":"b"},"extra":1}"#))
        var d = MCPServerDraft(server: o)
        d.transport = .sse
        d.url = "https://x.dev/sse"
        let json = d.json(original: o)
        #expect(json["url"]?.string == "https://x.dev/sse")
        #expect(json["command"] == nil && json["args"] == nil && json["cwd"] == nil && json["env"] == nil)
        #expect(json["extra"]?.int == 1)
    }

    @Test func enabledFalseIsWrittenAndTrueRemovesKey() throws {
        let o = try original()
        var d = MCPServerDraft(server: o)
        d.enabled = false
        #expect(d.json(original: o)["enabled"]?.bool == false)
        d.enabled = true
        #expect(d.json(original: o)["enabled"] == nil || d.json(original: o)["enabled"]?.bool == true)
        #expect(d.json(original: o)["disabled"] == nil)
    }

    @Test func validDraftHasNoProblems() throws {
        let o = try original()
        #expect(MCPServerDraft(server: o).problems(existingNames: ["gh", "other"]).isEmpty)
    }

    @Test func nameProblems() throws {
        var d = MCPServerDraft()
        d.command = "x"
        d.name = ""
        #expect(d.problems(existingNames: []).keys.contains("name"))
        d.name = "__proto__"
        #expect(d.problems(existingNames: []).keys.contains("name"))
        d.name = "dup"
        #expect(d.problems(existingNames: ["dup"]).keys.contains("name"))
        d.name = "fresh"
        #expect(d.problems(existingNames: ["dup"]).isEmpty)
    }

    @Test func emptyCommandAndUrl() {
        var d = MCPServerDraft()
        d.name = "a"
        #expect(d.problems(existingNames: []).keys.contains("command"))
        d.transport = .sse
        #expect(d.problems(existingNames: []).keys.contains("url"))
        d.url = "https://x.dev"
        #expect(d.problems(existingNames: []).isEmpty)
    }

    @Test func renameWithRedactedSecretsRequiresReentry() throws {
        let o = try original()
        var d = MCPServerDraft(server: o)
        d.name = "gh2"
        #expect(d.isRename)
        let problems = d.problems(existingNames: ["gh"])
        #expect(problems["headers.Authorization"] != nil)
        #expect(problems["headers.X"] == nil)
        // Re-entering the value clears it.
        if let index = d.headers.firstIndex(where: { $0.key == "Authorization" }) {
            d.headers[index].value = "Bearer new"
            d.headers[index].isRedacted = false
        }
        #expect(d.problems(existingNames: ["gh"]).isEmpty)
    }

    @Test func renameOntoExistingNameIsAProblem() throws {
        let o = try original()
        var d = MCPServerDraft(server: o)
        d.name = "other"
        #expect(d.problems(existingNames: ["gh", "other"]).keys.contains("name"))
    }
}

@Suite("MCP servers: status")
struct MCPServerStatusTests {
    @Test func connected() {
        let s = MCPServerStatus(json: Fixtures.json(#"{"name":"fs","enabled":true,"state":"connected","toolCount":4,"tools":["a","b"]}"#))
        #expect(s.name == "fs" && s.state == .connected && s.toolCount == 4 && s.tools == ["a", "b"] && s.auth == nil && !s.needsSignIn)
    }

    @Test func errorCarriesMessageAndTime() {
        let s = MCPServerStatus(json: Fixtures.json(#"{"name":"pg","state":"error","lastError":{"message":"spawn uvx ENOENT","at":1700000000000}}"#))
        #expect(s.state == .error && s.lastError == "spawn uvx ENOENT" && s.lastErrorAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func backoffRetryTime() {
        let s = MCPServerStatus(json: Fixtures.json(#"{"name":"x","state":"backoff","nextRetryAt":1700000005000}"#))
        #expect(s.state == .backoff && s.nextRetryAt == Date(timeIntervalSince1970: 1_700_000_005))
    }

    @Test func unknownStateDecodesToUnknown() {
        #expect(MCPServerStatus(json: Fixtures.json(#"{"name":"x","state":"warp-drive"}"#)).state == .unknown)
    }

    @Test func authRequiresSignIn() {
        let s = MCPServerStatus(json: Fixtures.json(#"{"name":"l","state":"idle","auth":{"mode":"oauth-shared","state":"requires-authorization"}}"#))
        #expect(s.needsSignIn && s.auth?.state == .requiresAuthorization && s.auth?.isExpired == false)
        let u = MCPServerStatus(json: Fixtures.json(#"{"name":"l","state":"idle","auth":{"mode":"oauth-shared","state":"unauthenticated"}}"#))
        #expect(u.needsSignIn)
    }

    @Test func authExpired() {
        let past = Int(Date().timeIntervalSince1970 * 1000) - 60_000
        let future = Int(Date().timeIntervalSince1970 * 1000) + 3_600_000
        let expired = MCPServerStatus(json: Fixtures.json(#"{"name":"n","state":"idle","auth":{"mode":"oauth-shared","state":"requires-authorization","expiresAt":\#(past)}}"#))
        #expect(expired.auth?.isExpired == true && expired.needsSignIn)
        let authorized = MCPServerStatus(json: Fixtures.json(#"{"name":"n","state":"connected","auth":{"mode":"oauth-shared","state":"authorized","expiresAt":\#(past),"account":"a@b.c"}}"#))
        #expect(authorized.auth?.isExpired == false && authorized.auth?.account == "a@b.c" && !authorized.needsSignIn)
        let live = MCPServerStatus(json: Fixtures.json(#"{"name":"n","state":"idle","auth":{"mode":"oauth-shared","state":"requires-authorization","expiresAt":\#(future)}}"#))
        #expect(live.auth?.isExpired == false)
    }

    @Test func pendingAuthorization() {
        let s = MCPServerStatus(json: Fixtures.json(#"{"name":"l","state":"idle","auth":{"mode":"oauth-shared","state":"pending-authorization"}}"#))
        #expect(s.auth?.state == .pendingAuthorization && !s.needsSignIn)
    }

    @Test func oauthAttemptSimulation() throws {
        let demo = MCPOAuthAttempt(id: "a", server: "l", authorizationURL: try #require(URL(string: "pincer-demo-oauth://authorize?attempt=a")), expiresAt: nil)
        let real = MCPOAuthAttempt(id: "b", server: "l", authorizationURL: try #require(URL(string: "https://x.dev/authorize")), expiresAt: nil)
        #expect(demo.isSimulated && !real.isSimulated)
    }
}
