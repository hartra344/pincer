import Foundation
import Testing
@testable import PincerKit

private let redacted = "__OPENCLAW_REDACTED__"

private func srv(_ json: String, name: String = "s") -> MCPServer {
    MCPServer(name: name, json: Fixtures.json(json))!
}

@Suite("MCP servers: advanced fields (#358)")
struct MCPAdvancedDraftTests {
    private let full = #"""
    {"url":"https://a.b/mcp","transport":"streamable-http","auth":"oauth","connectionTimeoutMs":5000,"requestTimeoutMs":60000,
     "toolFilter":{"include":["read_*"],"exclude":["rm"],"futureFilterKey":1},"sslVerify":false,"clientCert":"/c.pem","clientKey":"/k.pem",
     "oauth":{"identity":"per-requester","scope":"read write","authProfileId":"prof","futureOauth":true},"futureKey":{"a":1}}
    """#

    @Test func parsesEveryField() {
        let s = srv(full)
        #expect(s.connectionTimeoutMs == 5000 && s.requestTimeoutMs == 60000)
        #expect(s.toolInclude == ["read_*"] && s.toolExclude == ["rm"])
        #expect(s.sslVerify == false && s.clientCert == "/c.pem" && s.clientKey == "/k.pem")
        #expect(s.oauthIdentity == "per-requester" && s.oauthScope == "read write" && s.oauthAuthProfileId == "prof")
    }

    @Test func untouchedRoundTripKeepsEverything() {
        let o = srv(full)
        let json = MCPServerDraft(server: o).json(original: o)
        #expect(json["connectionTimeoutMs"]?.int == 5000 && json["requestTimeoutMs"]?.int == 60000)
        #expect(json["toolFilter"]?["include"]?[0]?.string == "read_*" && json["toolFilter"]?["exclude"]?[0]?.string == "rm")
        #expect(json["toolFilter"]?["futureFilterKey"]?.int == 1)
        #expect(json["sslVerify"]?.bool == false)
        #expect(json["clientCert"]?.string == "/c.pem" && json["clientKey"]?.string == "/k.pem")
        #expect(json["oauth"]?["identity"]?.string == "per-requester" && json["oauth"]?["scope"]?.string == "read write")
        #expect(json["oauth"]?["authProfileId"]?.string == "prof" && json["oauth"]?["futureOauth"]?.bool == true)
        #expect(json["futureKey"]?["a"]?.int == 1)
        #expect(json["auth"]?.string == "oauth")
    }

    @Test func newValuesAreWritten() {
        var d = MCPServerDraft()
        d.name = "n"
        d.transport = .streamableHTTP
        d.url = "https://x.dev/mcp"
        d.usesOAuth = true
        d.connectionTimeoutMs = " 1500 "
        d.requestTimeoutMs = "9000"
        d.toolInclude = [" a ", "", "b"]
        d.toolExclude = ["c"]
        d.sslVerify = false
        d.clientCert = " /c "
        d.oauthIdentity = "shared"
        d.oauthScope = "s"
        d.oauthAuthProfileId = "p"
        let json = d.json(original: nil)
        #expect(json["connectionTimeoutMs"]?.int == 1500 && json["requestTimeoutMs"]?.int == 9000)
        #expect(json["toolFilter"]?["include"]?.array?.compactMap(\.string) == ["a", "b"])
        #expect(json["toolFilter"]?["exclude"]?.array?.compactMap(\.string) == ["c"])
        #expect(json["sslVerify"]?.bool == false && json["clientCert"]?.string == "/c" && json["clientKey"] == nil)
        #expect(json["oauth"]?["identity"]?.string == "shared" && json["oauth"]?["scope"]?.string == "s" && json["oauth"]?["authProfileId"]?.string == "p")
    }

    @Test func clearingRemovesKeys() {
        let o = srv(full)
        var d = MCPServerDraft(server: o)
        d.connectionTimeoutMs = ""
        d.requestTimeoutMs = "  "
        d.clientCert = ""
        d.clientKey = ""
        d.oauthScope = ""
        d.oauthAuthProfileId = ""
        d.oauthIdentity = ""
        d.sslVerify = true
        let json = d.json(original: o)
        #expect(json["connectionTimeoutMs"] == nil && json["requestTimeoutMs"] == nil)
        #expect(json["clientCert"] == nil && json["clientKey"] == nil && json["sslVerify"] == nil)
        // Only the unknown oauth key remains.
        #expect(json["oauth"]?["identity"] == nil && json["oauth"]?["scope"] == nil && json["oauth"]?["authProfileId"] == nil)
        #expect(json["oauth"]?["futureOauth"]?.bool == true)
        #expect(json["futureKey"] != nil)
    }

    @Test func oauthObjectRemovedWhenEmpty() {
        let o = srv(#"{"url":"https://a.b/mcp","auth":"oauth","oauth":{"scope":"x"}}"#)
        var d = MCPServerDraft(server: o)
        d.oauthScope = ""
        #expect(d.json(original: o)["oauth"] == nil)
    }

    @Test func toolFilterRemovedWhenBothListsEmpty() {
        let o = srv(#"{"command":"x","toolFilter":{"include":["a"],"exclude":["b"]}}"#)
        var d = MCPServerDraft(server: o)
        d.toolInclude = []
        let half = d.json(original: o)
        #expect(half["toolFilter"]?["include"] == nil && half["toolFilter"]?["exclude"]?[0]?.string == "b")
        d.toolExclude = ["  "]
        #expect(d.json(original: o)["toolFilter"] == nil)
    }

    @Test func toolFilterKeepsUnknownKeysWhenListsEmpty() {
        let o = srv(#"{"command":"x","toolFilter":{"include":["a"],"mode":"strict"}}"#)
        var d = MCPServerDraft(server: o)
        d.toolInclude = []
        let json = d.json(original: o)
        #expect(json["toolFilter"]?["mode"]?.string == "strict" && json["toolFilter"]?["include"] == nil)
    }

    @Test func sslVerifyOnlyWrittenWhenOff() {
        var d = MCPServerDraft()
        d.name = "n"
        d.transport = .sse
        d.url = "https://x.dev/sse"
        #expect(d.json(original: nil)["sslVerify"] == nil)
        d.sslVerify = false
        #expect(d.json(original: nil)["sslVerify"]?.bool == false)
        // An explicit `true` in the original stays.
        let o = srv(#"{"url":"https://a.b/sse","sslVerify":true}"#)
        #expect(MCPServerDraft(server: o).json(original: o)["sslVerify"]?.bool == true)
        // Absent stays absent.
        let plain = srv(#"{"url":"https://a.b/sse"}"#)
        #expect(MCPServerDraft(server: plain).json(original: plain)["sslVerify"] == nil)
        // Turning it back on removes `false`.
        let off = srv(#"{"url":"https://a.b/sse","sslVerify":false}"#)
        var back = MCPServerDraft(server: off)
        back.sslVerify = true
        #expect(back.json(original: off)["sslVerify"] == nil)
    }

    @Test func switchingToStdioDropsRemoteOnlyKeysAndListsThem() {
        let o = srv(full)
        var d = MCPServerDraft(server: o)
        d.transport = .stdio
        d.command = "npx"
        let json = d.json(original: o)
        for key in ["sslVerify", "clientCert", "clientKey", "oauth", "auth", "url", "headers"] { #expect(json[key] == nil, "\(key)") }
        // Timeouts and filter are not transport specific.
        #expect(json["connectionTimeoutMs"]?.int == 5000 && json["toolFilter"] != nil && json["futureKey"] != nil)
        let dropped = d.droppedFieldsOnTransportChange
        for label in ["URL", "OAuth options", "TLS settings"] { #expect(dropped.contains(label), "\(label): \(dropped)") }
    }

    @Test func stdioDraftIgnoresRemoteFieldsSetInTheDraft() {
        var d = MCPServerDraft()
        d.name = "n"
        d.command = "x"
        d.sslVerify = false
        d.clientCert = "/c"
        d.oauthScope = "s"
        let json = d.json(original: nil)
        #expect(json["sslVerify"] == nil && json["clientCert"] == nil && json["oauth"] == nil)
    }

    @Test func timeoutValidation() {
        var d = MCPServerDraft()
        d.name = "n"
        d.command = "x"
        for bad in ["abc", "0", "-5", "1.5", "1e3", "١٢", "12ms", "0000"] {
            d.connectionTimeoutMs = bad
            d.requestTimeoutMs = bad
            let problems = d.problems(existingNames: [])
            #expect(problems["connectionTimeoutMs"] == "Enter a whole number of milliseconds.", "\(bad)")
            #expect(problems["requestTimeoutMs"] != nil, "\(bad)")
        }
        for good in ["", "  ", "1", "30000", " 250 "] {
            d.connectionTimeoutMs = good
            d.requestTimeoutMs = good
            #expect(d.problems(existingNames: []).isEmpty, "'\(good)'")
        }
        // An invalid timeout is never written.
        d.connectionTimeoutMs = "abc"
        #expect(d.json(original: nil)["connectionTimeoutMs"] == nil)
    }

    @Test func oauthIdentityValidation() {
        var d = MCPServerDraft()
        d.name = "n"
        d.transport = .streamableHTTP
        d.url = "https://x.dev/mcp"
        d.usesOAuth = true
        d.oauthIdentity = "bogus"
        #expect(d.problems(existingNames: [])["oauthIdentity"] != nil)
        for ok in ["", "shared", "per-requester"] {
            d.oauthIdentity = ok
            #expect(d.problems(existingNames: []).isEmpty, "\(ok)")
        }
    }

    @Test func perRequesterForbidsAuthProfile() {
        var d = MCPServerDraft()
        d.name = "n"
        d.transport = .streamableHTTP
        d.url = "https://x.dev/mcp"
        d.usesOAuth = true
        d.oauthIdentity = "per-requester"
        d.oauthAuthProfileId = "prof"
        #expect(d.problems(existingNames: [])["oauthAuthProfileId"] == "Per-person sign-in can't use an auth profile.")
        d.oauthIdentity = "shared"
        #expect(d.problems(existingNames: []).isEmpty)
        d.oauthIdentity = "per-requester"
        d.oauthAuthProfileId = "  "
        #expect(d.problems(existingNames: []).isEmpty)
    }

    @Test func otherOAuthKeysArePreserved() {
        let o = srv(#"{"url":"https://a.b/mcp","auth":"oauth","oauth":{"redirectUrl":"https://r.dev/cb","clientMetadataUrl":"https://m.dev/c.json","identity":"shared"},"supportsParallelToolCalls":true}"#)
        var d = MCPServerDraft(server: o)
        d.oauthScope = "read"
        let json = d.json(original: o)
        #expect(json["oauth"]?["redirectUrl"]?.string == "https://r.dev/cb" && json["oauth"]?["clientMetadataUrl"]?.string == "https://m.dev/c.json")
        #expect(json["oauth"]?["scope"]?.string == "read" && json["supportsParallelToolCalls"]?.bool == true)
    }

    @Test func redactedClientCertRoundTripsAndDropsOnStdio() {
        let o = srv(#"{"url":"https://a.b/mcp","clientCert":"\#(redacted)","clientKey":"\#(redacted)"}"#)
        #expect(o.clientCert == redacted)
        let d = MCPServerDraft(server: o)
        #expect(d.clientCert == redacted && d.clientKey == redacted)
        let json = d.json(original: o)
        #expect(json["clientCert"]?.string == redacted && json["clientKey"]?.string == redacted)
    }

    @Test func toolFilterAndTimeoutsPatchOnlyChanges() {
        let base: JSONValue = ["mcp": ["servers": ["s": ["command": "x", "requestTimeoutMs": 100, "toolFilter": ["include": ["a"]]]]]]
        let o = MCPServers.servers(in: base)[0]
        var d = MCPServerDraft(server: o)
        d.requestTimeoutMs = ""
        d.toolInclude = []
        var edits = ConfigEdits(base: base)
        edits.set(["mcp", "servers", "s"], d.json(original: o))
        let patch = edits.patch?["mcp"]?["servers"]?["s"]
        #expect(patch?["requestTimeoutMs"] == .null && patch?["toolFilter"] == .null)
        #expect(patch?["command"] == nil)
    }
}

@Suite("MCP probe and plugin servers (#357, #358)")
@MainActor
struct MCPProbeAndPluginTests {
    private func model(methods: Set<String>?, scopes: [String] = [GatewayConnection.adminScope],
                       request: @escaping MCPServersModel.Request) -> MCPServersModel
    {
        let settings = GatewaySettingsModel(connection: GatewayConnection(profile: .demo()), scopes: { scopes })
        return MCPServersModel(settings: settings, methods: { methods }, scopes: { scopes }, request: request)
    }

    @Test func probeIsGatedOnAdvertisement() async {
        var calls = 0
        let m = model(methods: ["mcp.status"]) { _, _ in calls += 1; return [:] }
        #expect(!m.supportsProbe)
        let result = await m.probe(name: "s")
        #expect(!result.ok && !result.diagnostics.isEmpty && calls == 0)
    }

    @Test func probeNeedsAdmin() async {
        var calls = 0
        let m = model(methods: ["mcp.probe"], scopes: ["operator.read"]) { _, _ in calls += 1; return [:] }
        let result = await m.probe(name: "s")
        #expect(!result.ok && calls == 0)
    }

    @Test func probeSendsNameDraftAndTimeout() async {
        var sent: (String, JSONValue)?
        let m = model(methods: ["mcp.probe"]) { method, params in
            sent = (method, params)
            return Fixtures.json(#"{"ok":true,"tools":[{"name":"a"},"b"],"resources":2,"prompts":["p"],"diagnostics":[{"message":"hi"},"plain"],"auth":{"mode":"oauth-shared","state":"authorized","account":"x@y.z"}}"#)
        }
        var draft = MCPServerDraft()
        draft.name = "new"
        draft.command = "node"
        draft.requestTimeoutMs = "500"
        let result = await m.probe(name: "new", draft: draft, timeoutMs: 4000)
        #expect(sent?.0 == "mcp.probe")
        #expect(sent?.1["serverName"]?.string == "new" && sent?.1["timeoutMs"]?.int == 4000)
        #expect(sent?.1["server"]?["command"]?.string == "node" && sent?.1["server"]?["requestTimeoutMs"]?.int == 500)
        #expect(result.ok && result.tools == ["a", "b"] && result.toolCount == 2 && result.resources == 2 && result.prompts == 1)
        #expect(result.diagnostics == ["hi", "plain"] && result.auth?.state == .authorized && result.auth?.account == "x@y.z")
    }

    @Test func probeOfSavedServerSendsNoDraft() async {
        var sent: JSONValue?
        let m = model(methods: ["mcp.probe"]) { _, params in sent = params; return ["ok": true] }
        let result = await m.probe(name: "saved")
        #expect(result.ok && result.tools.isEmpty && sent?["server"] == nil && sent?["timeoutMs"]?.int == MCPServersModel.defaultProbeTimeoutMs)
    }

    @Test func probeTimeoutPrecedence() async {
        var timeouts: [Int?] = []
        let m = model(methods: ["mcp.probe"]) { _, params in timeouts.append(params["timeoutMs"]?.int); return ["ok": true] }
        #expect(MCPServersModel.defaultProbeTimeoutMs == 15_000)
        var draft = MCPServerDraft()
        draft.name = "n"
        draft.command = "x"
        _ = await m.probe(name: "n", draft: draft)
        draft.connectionTimeoutMs = "2500"
        _ = await m.probe(name: "n", draft: draft)
        _ = await m.probe(name: "n", draft: draft, timeoutMs: 900)
        draft.connectionTimeoutMs = "abc"
        _ = await m.probe(name: "n", draft: draft)
        #expect(timeouts == [15_000, 2500, 900, 15_000])
    }

    @Test func unsavedDraftAlwaysSendsServer() async {
        var sent: JSONValue?
        let m = model(methods: ["mcp.probe"]) { _, params in sent = params; return ["ok": true] }
        var draft = MCPServerDraft()
        draft.name = "n"
        draft.command = "x"
        _ = await m.probe(name: "n", draft: draft)
        #expect(sent?["server"]?["command"]?.string == "x")
    }

    @Test func probeFailureShapesAndErrors() async {
        let m = model(methods: ["mcp.probe"]) { _, _ in
            Fixtures.json(#"{"ok":false,"diagnostics":[{"message":"spawn ENOENT"}]}"#)
        }
        let failed = await m.probe(name: "s")
        #expect(!failed.ok && failed.diagnostics == ["spawn ENOENT"])
        struct Boom: Error {}
        let thrown = model(methods: ["mcp.probe"]) { _, _ in throw Boom() }
        let result = await thrown.probe(name: "s")
        #expect(!result.ok && result.diagnostics.count == 1)
        // A missing `ok` is a failure, not a success.
        let empty = await model(methods: ["mcp.probe"]) { _, _ in [:] }.probe(name: "s")
        #expect(!empty.ok)
    }

    @Test func pluginServersParsedFromInspectShape() {
        let inspect = Fixtures.json(#"""
        {"ok":true,"plugin":{"id":"asana","name":"Asana"},
         "declared":{"mcpServers":["asana","asana-beta","asana"]},
         "components":{"mcpServers":["asana"],"unavailable":{"mcpServers":["asana-beta"]}},
         "mcpAuth":[{"serverName":"asana","state":"requires-authorization"},{"serverName":"other","state":"authorized"},{"state":"authorized"},{"serverName":"x","state":"warp"}]}
        """#)
        let servers = PluginMCPServer.servers(inspect: inspect)
        #expect(servers.map(\.name) == ["asana", "asana-beta"])
        #expect(servers[0].pluginId == "asana" && servers[0].pluginName == "Asana" && servers[0].isAvailable)
        #expect(servers[0].auth?.state == .requiresAuthorization)
        #expect(!servers[1].isAvailable && servers[1].auth == nil)
        #expect(servers[0].id != servers[1].id)
    }

    @Test func authStatesMap() {
        for (raw, state) in [("authorized", MCPAuthState.authorized), ("requires-authorization", .requiresAuthorization),
                             ("pending-authorization", .pendingAuthorization), ("unauthenticated", .unauthenticated)]
        {
            let inspect = Fixtures.json(#"{"plugin":{"id":"p"},"declared":{"mcpServers":["a"]},"mcpAuth":[{"serverName":"a","state":"\#(raw)"}]}"#)
            #expect(PluginMCPServer.servers(inspect: inspect).first?.auth?.state == state, "\(raw)")
        }
    }

    @Test func pluginServersMissingData() {
        let noAuth = PluginMCPServer.servers(inspect: Fixtures.json(#"{"plugin":{"id":"p"},"declared":{"mcpServers":["a","b"]}}"#))
        #expect(noAuth.map(\.name) == ["a", "b"] && noAuth.allSatisfy { $0.pluginName == nil && $0.auth == nil && $0.isAvailable })
        #expect(PluginMCPServer.servers(inspect: Fixtures.json(#"{"plugin":{"id":"p"}}"#)).isEmpty)
        #expect(PluginMCPServer.servers(inspect: Fixtures.json(#"{"plugin":{"id":"p"},"declared":{}}"#)).isEmpty)
        #expect(PluginMCPServer.servers(inspect: Fixtures.json(#"{"declared":{"mcpServers":["a"]}}"#)).isEmpty)
    }

    private func pluginRequest(_ log: @escaping @MainActor (String) -> Void) -> MCPServersModel.Request {
        { method, params in
            log(method)
            switch method {
            case "plugins.list":
                return Fixtures.json(#"{"plugins":[{"id":"linear","name":"Linear","installed":true,"enabled":true},{"id":"off","installed":true,"enabled":false},{"id":"gone","installed":false,"enabled":true}]}"#)
            case "plugins.inspect":
                let id = params["pluginId"]?.string ?? ""
                log("inspect:\(id)")
                return Fixtures.json(#"{"plugin":{"id":"\#(id)","name":"Linear"},"declared":{"mcpServers":["linear"]},"mcpAuth":[{"serverName":"linear","state":"requires-authorization"}]}"#)
            case "mcp.status":
                return Fixtures.json(#"{"servers":[{"name":"linear","source":"plugin","pluginId":"linear","state":"idle","auth":{"mode":"oauth-shared","state":"authorized","account":"a@b.c"}},{"name":"cfg","state":"connected"}]}"#)
            default:
                return [:]
            }
        }
    }

    @Test func loadReadsPluginServersOnlyWhenAdvertised() async {
        var log: [String] = []
        let hidden = model(methods: ["plugins.list"], request: pluginRequest { log.append($0) })
        await hidden.load()
        #expect(!hidden.supportsPluginServers && hidden.pluginServers.isEmpty && !log.contains("plugins.inspect"))
        let none = model(methods: nil, request: pluginRequest { log.append($0) })
        await none.load()
        #expect(none.pluginServers.isEmpty)

        log = []
        let shown = model(methods: ["plugins.list", "plugins.inspect"], request: pluginRequest { log.append($0) })
        await shown.load()
        #expect(shown.supportsPluginServers)
        #expect(shown.pluginServers.map(\.name) == ["linear"] && shown.pluginServers.first?.pluginId == "linear")
        // Disabled and uninstalled plugins are not inspected.
        #expect(log.filter { $0.hasPrefix("inspect:") } == ["inspect:linear"])
        #expect(shown.pluginServers.first?.auth?.state == .requiresAuthorization)
    }

    @Test func liveStatusMergesForPluginSourceEntries() async {
        var log: [String] = []
        let m = model(methods: ["plugins.list", "plugins.inspect", "mcp.status"], request: pluginRequest { log.append($0) })
        await m.load()
        let plugin = m.pluginServers[0]
        let live = m.status(for: plugin)
        #expect(live?.state == .idle && live?.auth?.state == .authorized)
        // Config-sourced entries are not plugin statuses.
        #expect(m.pluginStatuses.keys.sorted() == ["linear/linear"] && live?.state == .idle)
    }

    @Test func pluginStatusNeedsPluginIdAndSource() async {
        let m = model(methods: ["plugins.list", "plugins.inspect", "mcp.status"]) { method, params in
            switch method {
            case "plugins.list": return Fixtures.json(#"{"plugins":[{"id":"linear","installed":true,"enabled":true}]}"#)
            case "plugins.inspect": return Fixtures.json(#"{"plugin":{"id":"linear"},"declared":{"mcpServers":["linear"]}}"#)
            case "mcp.status":
                return Fixtures.json(#"{"servers":[{"name":"linear","source":"plugin","state":"idle"},{"name":"linear","source":"config","pluginId":"linear","state":"connected"},{"name":"x","source":"plugin","pluginId":"other","state":"error"}]}"#)
            default: return [:]
            }
        }
        await m.load()
        #expect(m.pluginStatuses.keys.sorted() == ["other/x"])
        #expect(m.status(for: m.pluginServers[0]) == nil)
    }

    @Test func probeStripsEnabledForDisabledServers() async {
        var sent: JSONValue?
        let m = model(methods: ["mcp.probe"]) { _, params in sent = params; return ["ok": true] }
        var draft = MCPServerDraft()
        draft.name = "n"
        draft.command = "x"
        draft.enabled = false
        _ = await m.probe(name: "n", draft: draft)
        #expect(sent?["server"]?["command"]?.string == "x" && sent?["server"]?["enabled"] == nil)
    }

    @Test func noLiveStatusMeansNoPluginStatus() async {
        var log: [String] = []
        let m = model(methods: ["plugins.list", "plugins.inspect"], request: pluginRequest { log.append($0) })
        await m.load()
        #expect(m.pluginServers.count == 1 && m.status(for: m.pluginServers[0]) == nil)
    }

    @Test func pluginListFailureKeepsLoadWorking() async {
        struct Boom: Error {}
        let m = model(methods: ["plugins.list", "plugins.inspect"]) { method, _ in
            if method.hasPrefix("plugins") { throw Boom() }
            return [:]
        }
        await m.load()
        #expect(m.pluginServers.isEmpty)
    }
}
