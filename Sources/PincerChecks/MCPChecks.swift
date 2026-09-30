import Foundation
import PincerKit

// MCP Servers (#323): the model against the built-in demo, then against a (fresh) mock Gateway, including
// the real HTTP OAuth round trip and redacted secrets surviving an unrelated edit.

private let seedNames = ["acme.docs", "filesystem", "github", "home-assistant", "linear", "notion", "postgres", "sentry"]

@MainActor
private func mcpConnect(_ profile: GatewayProfile, _ label: String) async -> GatewayStore? {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let up = await waitFor("\(label) connected", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(up, "\(label) connected")
    guard up else { gateway.stop(); return nil }
    return gateway
}

@MainActor
private func mcpSeedChecks(_ mcp: MCPServersModel, label: String) {
    check(mcp.servers.map(\.name) == seedNames, "\(label): lists the 8 seed servers (\(mcp.servers.map(\.name)))")
    func state(_ name: String) -> MCPServerState { mcp.status(for: name).state }
    check(state("filesystem") == .connected && mcp.status(for: "filesystem").toolCount == 4, "\(label): filesystem connected, 4 tools")
    check(state("home-assistant") == .connected && mcp.status(for: "home-assistant").toolCount == 2, "\(label): home-assistant connected, 2 tools")
    check(state("github") == .connected && mcp.status(for: "github").toolCount == 6, "\(label): github connected, 6 tools")
    check(mcp.server("github")?.transport == .streamableHTTP && mcp.server("github")?.headers.first?.isRedacted == true,
          "\(label): github is streamable HTTP with a redacted header")
    check(mcp.server("sentry")?.transport == .sse && state("sentry") == .disabled, "\(label): sentry is a disabled SSE server")
    check(mcp.server("filesystem")?.launchSummary == "npx -y @modelcontextprotocol/server-filesystem /Users/demo/Projects",
          "\(label): filesystem launch summary (\(mcp.server("filesystem")?.launchSummary ?? "nil"))")
    let ha = mcp.server("home-assistant")?.launchSummary ?? ""
    check(ha.contains("--token ••••"), "\(label): home-assistant token arg masked (\(ha))")
    let linear = mcp.status(for: "linear")
    check(linear.needsSignIn && linear.auth?.state == .requiresAuthorization && !(linear.auth?.isExpired ?? true),
          "\(label): linear needs sign-in, not expired")
    let notion = mcp.status(for: "notion")
    check(notion.needsSignIn && notion.auth?.isExpired == true, "\(label): notion sign-in expired")
    let postgres = mcp.status(for: "postgres")
    check(postgres.state == .error && postgres.lastError?.contains("ENOENT") == true, "\(label): postgres error (\(postgres.lastError ?? "nil"))")
}

/// Signs in to linear via the demo's simulated consent (start + completeSignIn(code:"demo")), then out again.
@MainActor
private func mcpDemoSignIn(_ mcp: MCPServersModel) async {
    guard let attempt = await mcp.startSignIn("linear") else {
        check(false, "demo: linear sign-in starts (\(mcp.operation(for: "linear").error ?? "nil"))")
        return
    }
    check(attempt.isSimulated && attempt.server == "linear", "demo: sign-in is simulated (\(attempt.authorizationURL))")
    let ok = await mcp.completeSignIn(attempt, code: "demo", callbackURL: nil)
    let linear = mcp.status(for: "linear")
    check(ok && linear.state == .connected && linear.auth?.state == .authorized && linear.auth?.account == "demo@pincer.app" && linear.toolCount == 5,
          "demo: linear authorized as demo@pincer.app with 5 tools (\(linear.state), \(String(describing: linear.auth?.account)), \(String(describing: linear.toolCount)))")
    await mcp.signOut("linear")
    check(mcp.status(for: "linear").needsSignIn && mcp.status(for: "linear").auth?.account == nil, "demo: sign out → needs sign-in")
    if let second = await mcp.startSignIn("linear") {
        await mcp.cancelSignIn(second)
        check(mcp.status(for: "linear").needsSignIn, "demo: cancelled sign-in stays signed out")
    }
}

/// Plugin-declared servers (#357) and Test Connection (#358), in the shape both gateways share.
@MainActor
private func mcpPluginAndProbeChecks(_ gateway: GatewayStore, label: String) async {
    let mcp = gateway.mcp
    check(mcp.supportsPluginServers && mcp.supportsProbe, "\(label): advertises plugins.inspect and mcp.probe")
    let byName = Dictionary(mcp.pluginServers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    check(Set(byName.keys).isSuperset(of: ["linear", "asana"]), "\(label): plugin-declared servers include linear and asana (\(mcp.pluginServers.map(\.name)))")
    let linear = byName["linear"], asana = byName["asana"]
    check(linear?.pluginId == "linear" && linear?.pluginName == "Linear" && linear?.isAvailable == true,
          "\(label): linear plugin server (\(String(describing: linear?.pluginName)) available \(String(describing: linear?.isAvailable)))")
    // `mcpAuth` only covers servers matching a configured OAuth server, so linear follows the configured `linear`.
    check(linear?.auth?.state != nil && linear?.auth?.state == mcp.status(for: "linear").auth?.state,
          "\(label): plugin linear auth follows the configured linear server (\(String(describing: linear?.auth?.state)))")
    check(asana?.isAvailable == true && (asana?.auth == nil || asana?.auth?.state == .requiresAuthorization), "\(label): plugin asana is available and not signed in")
    if let beta = byName["asana-beta"] {
        check(!beta.isAvailable && beta.auth == nil && beta.pluginId == "asana", "\(label): asana-beta is listed as unavailable")
    }
    check(mcp.servers.map(\.name) == seedNames, "\(label): plugin servers are not in the configured list")
    check(!mcp.servers.map(\.name).contains("asana"), "\(label): plugin server is not editable config")

    let saved = await mcp.probe(name: "filesystem")
    check(saved.ok && saved.toolCount == 4 && saved.diagnostics.isEmpty, "\(label): probe filesystem ok with 4 tools (\(saved.ok) \(saved.toolCount) \(saved.diagnostics))")
    let broken = await mcp.probe(name: "postgres")
    check(!broken.ok && broken.diagnostics.contains { $0.contains("ENOENT") }, "\(label): probe postgres fails with ENOENT (\(broken.diagnostics))")
    check(broken.diagnostics.count == 3, "\(label): probe postgres reports 3 diagnostics (\(broken.diagnostics.count))")
    let github = await mcp.probe(name: "github")
    check(github.ok && github.toolCount == 6 && github.resources == 3 && github.prompts == 2,
          "\(label): probe github: 6 tools, 3 resources, 2 prompts (\(github.toolCount) \(String(describing: github.resources)) \(String(describing: github.prompts)))")
    let tooSlow = await mcp.probe(name: "home-assistant", timeoutMs: 500)
    check(!tooSlow.ok && !tooSlow.diagnostics.isEmpty, "\(label): probe home-assistant times out under 2 s (\(tooSlow.diagnostics))")
    let slow = await mcp.probe(name: "home-assistant")
    check(slow.ok && slow.toolCount == 2, "\(label): probe home-assistant succeeds with the default timeout (\(slow.ok) \(slow.diagnostics))")
    let notion = await mcp.probe(name: "notion")
    check(!notion.ok && notion.auth != nil && notion.auth?.state != .authorized, "\(label): probe notion needs authorization")
    let disabled = await mcp.probe(name: "sentry")
    check(mcp.server("sentry")?.enabled == false && disabled.ok, "\(label): a disabled server can still be probed (\(disabled.diagnostics))")
    let acme = await mcp.probe(name: "acme.docs")
    check(acme.ok && acme.toolCount == 2, "\(label): probe acme.docs ok with 2 tools (\(acme.toolCount))")
    let oauth = await mcp.probe(name: "linear")
    check(!oauth.ok && oauth.auth?.state == .requiresAuthorization, "\(label): probe of signed-out linear reports requires-authorization (\(oauth.diagnostics))")
    let unknown = await mcp.probe(name: "no-such-server")
    check(!unknown.ok && !unknown.diagnostics.isEmpty, "\(label): probe of an unknown server fails with a message")

    var draft = MCPServerDraft()
    draft.name = "probe-draft"
    draft.command = "nonexistent-binary"
    let missing = await mcp.probe(name: draft.name, draft: draft)
    check(!missing.ok && missing.diagnostics.contains { $0.contains("ENOENT") }, "\(label): probe of a draft with a missing command fails (\(missing.diagnostics))")
    check(mcp.server("probe-draft") == nil && !mcp.isNew("probe-draft"), "\(label): probing a draft doesn't add it to the config")
    draft.command = "node"
    let fine = await mcp.probe(name: draft.name, draft: draft)
    check(fine.ok && fine.toolCount > 0, "\(label): probe of a draft with a working command connects (\(fine.diagnostics))")

    // An unchanged draft probes the saved entry by name only; an edited one sends its definition.
    if let filesystem = mcp.savedServer("filesystem") {
        var sent: [JSONValue] = []
        let recorder = MCPServersModel(settings: gateway.settings, methods: { gateway.hello?.methods }, request: { _, params in
            sent.append(params)
            return ["ok": true]
        })
        let same = MCPServerDraft(server: filesystem)
        _ = await recorder.probe(name: "filesystem", draft: same)
        var edited = MCPServerDraft(server: filesystem)
        edited.connectionTimeoutMs = "1234"
        _ = await recorder.probe(name: "filesystem", draft: edited)
        check(sent.count == 2 && sent[0]["server"] == nil && sent[0]["timeoutMs"]?.int == MCPServersModel.defaultProbeTimeoutMs,
              "\(label): unchanged draft sends only the name and the default timeout")
        check(sent.count == 2 && sent[1]["server"]?["connectionTimeoutMs"]?.int == 1234 && sent[1]["timeoutMs"]?.int == 1234,
              "\(label): edited draft sends its definition and its connection timeout")
    }

    if let filesystem = mcp.server("filesystem"), let first = saved.tools.first {
        var filtered = MCPServerDraft(server: filesystem)
        filtered.toolInclude = [first]
        let result = await mcp.probe(name: "filesystem", draft: filtered)
        check(result.ok && result.tools == [first], "\(label): probe honours the draft's tool filter (\(result.tools))")
        var excluded = MCPServerDraft(server: filesystem)
        excluded.toolExclude = [first]
        let rest = await mcp.probe(name: "filesystem", draft: excluded)
        check(rest.ok && rest.toolCount == saved.toolCount - 1 && !rest.tools.contains(first), "\(label): probe honours the draft's tool exclude (\(rest.toolCount))")
    }
}

/// Add (apply + save), disable/enable, reconnect and remove, in the shape both gateways share.
@MainActor
private func mcpLifecycle(_ gateway: GatewayStore, label: String, settleTimeout: Double) async {
    let mcp = gateway.mcp
    let settings = gateway.settings

    var draft = MCPServerDraft()
    draft.name = "scratch-tools"
    draft.command = "node"
    draft.args = ["server.js"]
    check(draft.problems(existingNames: Set(mcp.servers.map(\.name))).isEmpty, "\(label): new draft is valid")
    mcp.apply(draft)
    check(mcp.isNew("scratch-tools") && mcp.status(for: "scratch-tools").state == .unsaved, "\(label): unsaved draft shows Not Saved")
    check(settings.changeCount(under: ["mcp"]) > 0, "\(label): draft counts as an mcp change")
    let saved = await settings.save()
    check(saved, "\(label): save adds the server (\(settings.saveState.error ?? "ok"))")
    let connected = await waitFor("\(label) new server connected", timeout: settleTimeout) {
        mcp.status(for: "scratch-tools").state == .connected && mcp.status(for: "scratch-tools").toolCount == 3
    }
    check(connected, "\(label): new stdio server connects with 3 tools (\(mcp.status(for: "scratch-tools").state))")
    check(!mcp.isNew("scratch-tools") && !mcp.isChanged("scratch-tools"), "\(label): saved server is no longer new or changed")

    mcp.setEnabled("scratch-tools", false)
    check(mcp.isChanged("scratch-tools") && mcp.server("scratch-tools")?.enabled == false && mcp.status(for: "scratch-tools").state == .disabled,
          "\(label): disable is a draft change and reads Disabled")
    let ok57418 = await settings.save()
    check(ok57418, "\(label): save disable")
    check(mcp.savedServer("scratch-tools")?.enabled == false, "\(label): saved as enabled:false")
    mcp.setEnabled("scratch-tools", true)
    check(settings.value(at: ["mcp", "servers", "scratch-tools", "enabled"]) == nil, "\(label): enable removes the enabled key")
    let ok57806 = await settings.save()
    check(ok57806, "\(label): save enable")
    let w101 = await waitFor("\(label) re-enabled connects", timeout: settleTimeout) { mcp.status(for: "scratch-tools").state == .connected }
    check(w101, "\(label): re-enabled server connects again")

    // Rename nulls the old name.
    if let current = mcp.server("scratch-tools") {
        var rename = MCPServerDraft(server: current)
        rename.name = "scratch-renamed"
        mcp.apply(rename)
        check(mcp.server("scratch-tools") == nil && mcp.server("scratch-renamed") != nil, "\(label): rename moves the server in the draft")
        let ok84013 = await settings.save()
        check(ok84013, "\(label): save rename")
        check(mcp.savedServer("scratch-tools") == nil && mcp.savedServer("scratch-renamed") != nil, "\(label): rename saved, old name gone")
    }

    // Reconnect.
    if mcp.supportsReconnect {
        await mcp.reconnect("scratch-renamed")
        let w102 = await waitFor("\(label) reconnect settles", timeout: settleTimeout) { mcp.status(for: "scratch-renamed").state == .connected }
        check(w102, "\(label): reconnect ends connected")
        await mcp.reconnect("github")
        let w103 = await waitFor("\(label) github reconnect", timeout: settleTimeout) { mcp.status(for: "github").state == .connected }
        check(w103, "\(label): reconnect github stays connected")
    }

    mcp.remove("scratch-renamed")
    check(mcp.server("scratch-renamed") == nil, "\(label): remove drops it from the draft")
    let ok64427 = await settings.save()
    check(ok64427, "\(label): save remove")
    check(mcp.savedServer("scratch-renamed") == nil && mcp.servers.map(\.name) == seedNames, "\(label): back to the 8 seed servers (\(mcp.servers.map(\.name)))")
}

@MainActor
func runDemoMCP() async {
    guard let gateway = await mcpConnect(GatewayProfile.demo(), "demo for MCP") else { return }
    defer { gateway.stop() }
    await gateway.settings.load()
    let mcp = gateway.mcp
    check(gateway.supportsMCPServers && mcp.hasConfig && mcp.canEdit, "demo: MCP servers supported, editable without admin")
    check(mcp.supportsLiveStatus && mcp.supportsReconnect && mcp.supportsOAuth, "demo advertises mcp.status, mcp.reconnect and mcp.oauth.*")
    await mcp.load()
    mcpSeedChecks(mcp, label: "demo")
    await mcpPluginAndProbeChecks(gateway, label: "demo")
    await mcpDemoSignIn(mcp)
    await mcp.reconnect("github")
    check(mcp.status(for: "github").state == .connected, "demo: reconnect github stays connected")
    await mcp.reconnect("postgres")
    check(mcp.status(for: "postgres").state == .error, "demo: reconnect keeps postgres in error")
    await mcpLifecycle(gateway, label: "demo", settleTimeout: 5)
}

// MARK: Live

/// Doesn't follow redirects, so the pincer:// return URL can be read from the Location header.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private func fetch(_ url: URL) async -> (status: Int, body: String, location: String?)? {
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    guard let (data, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse else { return nil }
    return (http.statusCode, String(decoding: data, as: UTF8.self), http.value(forHTTPHeaderField: "Location"))
}

/// The href of the Allow link in the mock's consent page.
private func allowLink(in html: String, base: URL) -> URL? {
    for part in html.components(separatedBy: #"href=""#).dropFirst() {
        guard let href = part.components(separatedBy: "\"").first, href.contains("code=") else { continue }
        return URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
    }
    return nil
}

@MainActor
func runLiveMCP(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock MCP", url: url, authMode: .token, access: .admin)
    profile.secret = token
    guard let gateway = await mcpConnect(profile, "mock for MCP") else { return }
    defer { gateway.stop() }
    let settings = gateway.settings
    await settings.load()
    let mcp = gateway.mcp
    check(gateway.supportsMCPServers && mcp.hasConfig, "mock: MCP servers supported (config loaded)")
    guard settings.canEdit else { check(false, "mock: admin scope granted for MCP"); return }
    check(mcp.supportsLiveStatus && mcp.supportsReconnect && mcp.supportsOAuth, "mock advertises mcp.status, mcp.reconnect and mcp.oauth.*")
    await mcp.load()
    let ok29241 = await waitFor("mock statuses settle", timeout: 10) { mcp.status(for: "filesystem").state == .connected }
    check(ok29241, "mock: filesystem connects")
    mcpSeedChecks(mcp, label: "mock")
    await mcpPluginAndProbeChecks(gateway, label: "mock")

    // Secrets stay redacted in config.get, and an unrelated edit doesn't clobber them.
    let sentinel = "__OPENCLAW_REDACTED__"
    check(settings.savedValue(at: ["mcp", "servers", "github", "headers", "Authorization"])?.string == sentinel, "mock: github Authorization arrives redacted")
    if let filesystem = mcp.server("filesystem") {
        var edit = MCPServerDraft(server: filesystem)
        if let index = edit.env.firstIndex(where: { $0.key == "LOG_LEVEL" }) {
            edit.env[index].value = "debug"
            edit.env[index].isRedacted = false
        }
        mcp.apply(edit)
        check(mcp.isChanged("filesystem") && !mcp.isChanged("github"), "mock: only filesystem is changed")
        let r1 = await settings.save()
        check(r1, "mock: save unrelated edit (\(settings.saveState.error ?? "ok"))")
        check(!mcp.isChanged("filesystem"), "mock: filesystem is saved")
        check(settings.savedValue(at: ["mcp", "servers", "github", "headers", "Authorization"])?.string == sentinel,
              "mock: github Authorization still redacted in config.get after the edit")
        let control = MockControl(profile: profile)
        if await control.start(), let stored = await control.call("config") {
            let header = stored["config"]?["mcp"]?["servers"]?["github"]?["headers"]?["Authorization"]?.string
                ?? stored["mcp"]?["servers"]?["github"]?["headers"]?["Authorization"]?.string
            check(header != nil && header != sentinel && header?.isEmpty == false, "mock: github Authorization still set in the mock's stored config")
        } else {
            print("  (mock.control 'config' unavailable; skipping the stored-config check)")
        }
        await control.stop()
    }

    // Real HTTP OAuth: start → authorize page → Allow → callback redirect → mcp.oauth.changed refresh.
    if let attempt = await mcp.startSignIn("linear") {
        check(!attempt.isSimulated && attempt.authorizationURL.path.contains("/mcp-oauth/authorize"), "mock: sign-in gives an http authorization URL (\(attempt.authorizationURL))")
        check(mcp.status(for: "linear").needsSignIn, "mock: linear needs sign-in before Allow")
        if let page = await fetch(attempt.authorizationURL) {
            check(page.status == 200 && page.body.contains("Authorize Pincer Mock for linear"), "mock: consent page names the server")
            if let allow = allowLink(in: page.body, base: attempt.authorizationURL), let done = await fetch(allow) {
                check(done.status == 302 && done.location?.hasPrefix("pincer://mcp-oauth/done") == true && done.location?.contains("server=linear") == true,
                      "mock: callback redirects to the pincer:// return URL (\(done.status) \(done.location ?? "nil"))")
            } else {
                check(false, "mock: consent page has an Allow link (\(page.body.suffix(300)))")
            }
        } else {
            check(false, "mock: authorization page loads")
        }
        let authorized = await waitFor("mock linear authorized via event", timeout: 10) {
            mcp.status(for: "linear").auth?.state == .authorized && mcp.status(for: "linear").state == .connected
        }
        check(authorized && mcp.status(for: "linear").toolCount == 5, "mock: linear authorized with 5 tools after the oauth event (\(mcp.status(for: "linear").state))")
        await mcp.signOut("linear")
        let ok61191 = await waitFor("mock linear signed out", timeout: 10) { mcp.status(for: "linear").needsSignIn }
        check(ok61191, "mock: sign out → needs sign-in")
        // Deny path.
        if let denied = await mcp.startSignIn("linear"), let page = await fetch(denied.authorizationURL),
           var allow = allowLink(in: page.body, base: denied.authorizationURL), var parts = URLComponents(url: allow, resolvingAgainstBaseURL: false)
        {
            parts.queryItems = parts.queryItems?.filter { $0.name != "code" } ?? []
            parts.queryItems?.append(URLQueryItem(name: "error", value: "access_denied"))
            allow = parts.url ?? allow
            _ = await fetch(allow)
            let ok13947 = await waitFor("mock deny leaves linear signed out", timeout: 5) { mcp.status(for: "linear").needsSignIn }
            check(ok13947, "mock: denying leaves linear signed out")
        }
        // Manual complete path.
        if let manual = await mcp.startSignIn("linear") {
            let ok = await mcp.completeSignIn(manual, code: "manual-code", callbackURL: nil)
            _ = await waitFor("mock manual sign-in authorized", timeout: 5) { mcp.status(for: "linear").auth?.state == .authorized }
            check(ok && mcp.status(for: "linear").auth?.state == .authorized, "mock: oauth.complete with a code authorizes (\(ok), \(mcp.operation(for: "linear").error ?? "no error"), \(mcp.status(for: "linear").auth?.state as Any))")
            await mcp.signOut("linear")
        }
        if let cancelled = await mcp.startSignIn("linear") {
            await mcp.cancelSignIn(cancelled)
            check(mcp.status(for: "linear").needsSignIn, "mock: cancel leaves linear signed out")
        }
    } else {
        check(false, "mock: linear sign-in starts (\(mcp.operation(for: "linear").error ?? "nil"))")
    }
    // A non-OAuth server can't start sign-in.
    let refused = await mcp.startSignIn("filesystem")
    check(refused == nil, "mock: non-OAuth server can't sign in")

    await mcp.reconnect("postgres")
    let ok4614 = await waitFor("mock postgres still errors", timeout: 8) { mcp.status(for: "postgres").state == .error }
    check(ok4614, "mock: postgres stays in error after reconnect")
    await mcpLifecycle(gateway, label: "mock", settleTimeout: 10)
}
