import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the first-run setup wizard reads from the demo, shaped like `mock-gateway/setup.mjs`:
/// `channels.status` (Discord fine, Telegram degraded like `health`, WhatsApp not linked yet),
/// `skills.status` (one skill missing its CLI) and WhatsApp QR login over `web.login.start` /
/// `web.login.wait`, which the Gateway doesn't list in `hello.features.methods`.
struct DemoSetupState {
    var whatsappLinked = false
    var whatsappLinkedAt: Double?
    /// The running QR login: its id, how many QRs it has shown and waited on, and the current QR.
    var login: (id: String, qrSeq: Int, waits: Int, qrDataUrl: String)?
}

extension DemoGateway {
    static let setupMethods = ["channels.status", "skills.status"]
    static let webLoginMethods = ["web.login.start", "web.login.wait"]
    static let whatsappNotLinked = "Not linked (no WhatsApp Web session)."
    static let whatsappRelinkFix = "Run: openclaw channels login (scan QR on the gateway host)."
    static let missingSkill = "summarize"
    /// How long a demo `web.login.wait` takes, as if the user were scanning.
    static let webLoginWaitMs = 1200

    private static let setupChannelMeta: [(id: String, label: String, detail: String)] = [
        ("discord", "Discord", "Discord Bot"),
        ("telegram", "Telegram", "Telegram Bot"),
        ("whatsapp", "WhatsApp", "WhatsApp Web"),
    ]

    /// The WhatsApp account `health` and `channels.status` share: enabled, but not linked (so not
    /// configured) until the QR is scanned.
    func whatsappAccount() -> JSONValue {
        if self.setup.whatsappLinked {
            return [
                "accountId": "default", "name": "WhatsApp", "enabled": true, "configured": true, "linked": true,
                "running": true, "connected": true, "restartPending": false, "reconnectAttempts": 0,
                "lastConnectedAt": .number(self.setup.whatsappLinkedAt ?? (Self.now().double ?? 0)), "lifecycle": "ready",
                "healthState": "healthy",
            ]
        }
        return [
            "accountId": "default", "name": "WhatsApp", "enabled": true, "configured": false, "linked": false,
            "running": false, "connected": false, "restartPending": false, "reconnectAttempts": 0, "lifecycle": "stopped",
        ]
    }

    func handleSetup(_ method: String, _ params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "channels.status":
            try Self.closedParams(params, ["probe", "timeoutMs", "channel"], method)
            return try self.channelsStatus(params)
        case "skills.status":
            try Self.closedParams(params, ["agentId", "sessionKey"], method)
            let agentId = params["agentId"]?.text ?? "main"
            guard self.agentIds.contains(agentId) else { throw Self.invalid("unknown agent id \"\(agentId)\"") }
            if let key = params["sessionKey"]?.text, !self.hasSession(key) { throw Self.invalid("Session not found.") }
            return Self.skillsReport(agentId: agentId)
        case "web.login.start":
            try Self.closedParams(params, ["channel", "force", "timeoutMs", "verbose", "accountId"], method)
            try Self.webLoginChannel(params)
            return self.webLoginStart(force: params["force"]?.bool == true)
        case "web.login.wait":
            try Self.closedParams(params, ["channel", "sessionKey", "timeoutMs", "accountId", "currentQrDataUrl"], method)
            if let url = params["currentQrDataUrl"], url.text?.hasPrefix("data:image/png;base64,") != true {
                throw Self.invalid("invalid web.login.wait params: currentQrDataUrl must match pattern \"^data:image/png;base64,\"")
            }
            try Self.webLoginChannel(params)
            return try await self.webLoginWait(timeoutMs: params["timeoutMs"]?.int ?? 120_000)
        default:
            return nil
        }
    }

    // MARK: Channels

    private func channelsStatus(_ params: JSONValue) throws -> JSONValue {
        var filter: String?
        if let raw = params["channel"] {
            let id = raw.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard Self.setupChannelMeta.contains(where: { $0.id == id }) else {
                throw Self.invalid("unknown channel: \(raw.text ?? "")")
            }
            filter = id
        }
        let probe = params["probe"]?.bool == true
        let nowMs = Self.now().double ?? 0
        let health = self.health()["channels"]?.object ?? [:]
        let meta = Self.setupChannelMeta.filter { filter == nil || $0.id == filter }
        var channels: [String: JSONValue] = [:]
        var accounts: [String: JSONValue] = [:]
        var defaults: [String: JSONValue] = [:]
        for entry in meta {
            guard var account = health[entry.id]?.object else { continue }
            account["accountId"] = account["accountId"] ?? "default"
            account["lifecycle"] = nil
            account["accounts"] = nil
            if probe, account["configured"]?.bool == true, account["enabled"]?.bool != false {
                account["lastProbeAt"] = .number(nowMs)
                account["probe"] = ["ok": .bool(account["connected"]?.bool == true), "elapsedMs": 41]
            }
            var summary = account
            summary["accountId"] = nil
            summary["name"] = nil
            channels[entry.id] = .object(summary)
            accounts[entry.id] = [.object(account)]
            defaults[entry.id] = "default"
        }
        var result: [String: JSONValue] = [
            "ts": Self.now(),
            "channelOrder": .array(meta.map { .string($0.id) }),
            "channelLabels": .object(Dictionary(uniqueKeysWithValues: meta.map { ($0.id, JSONValue.string($0.label)) })),
            "channelDetailLabels": .object(Dictionary(uniqueKeysWithValues: meta.map { ($0.id, JSONValue.string($0.detail)) })),
            "channelMeta": .array(meta.map { ["id": .string($0.id), "label": .string($0.label), "detailLabel": .string($0.detail)] }),
            "channels": .object(channels),
            "channelAccounts": .object(accounts),
            "channelDefaultAccountId": .object(defaults),
        ]
        if meta.contains(where: { $0.id == "whatsapp" }), !self.setup.whatsappLinked {
            result["statusIssues"] = [[
                "channel": "whatsapp", "accountId": "default", "kind": "auth",
                "message": .string(Self.whatsappNotLinked), "fix": .string(Self.whatsappRelinkFix),
            ]]
        }
        return .object(result)
    }

    // MARK: Skills

    private static func skill(_ name: String, _ description: String, emoji: String, requires: [String] = [],
                              missing: [String] = [], os: [String] = [], missingOS: [String] = [],
                              install: [JSONValue] = []) -> JSONValue
    {
        func reqs(_ bins: [String], _ os: [String]) -> JSONValue {
            ["bins": JSONValue(bins), "anyBins": [], "env": [], "config": [], "os": JSONValue(os)]
        }
        let platformIncompatible = !missingOS.isEmpty
        let eligible = missing.isEmpty && missingOS.isEmpty
        return [
            "name": .string(name), "description": .string(description), "source": "openclaw-bundled", "bundled": true,
            "filePath": .string("/opt/openclaw/skills/\(name)/SKILL.md"), "baseDir": .string("/opt/openclaw/skills/\(name)"),
            "skillKey": .string(name), "emoji": .string(emoji), "always": false, "disabled": false,
            "blockedByAllowlist": false, "blockedByAgentFilter": false, "eligible": .bool(eligible),
            "platformIncompatible": .bool(platformIncompatible), "modelVisible": .bool(eligible), "userInvocable": true,
            "commandVisible": .bool(eligible), "requirements": reqs(requires, os), "missing": reqs(missing, missingOS),
            "configChecks": [], "install": platformIncompatible ? [] : .array(install),
        ]
    }

    private static func brew(_ label: String, _ bins: [String]) -> JSONValue {
        ["id": "brew", "kind": "brew", "label": .string(label), "bins": JSONValue(bins)]
    }

    /// Three ready skills, `summarize` missing its CLI, and a macOS-only one on the Linux Gateway.
    static func skillsReport(agentId: String) -> JSONValue {
        [
            "workspaceDir": .string(agentId == "main" ? "~/.openclaw/workspace" : "~/.openclaw/workspace-\(agentId)"),
            "managedSkillsDir": "~/.openclaw/skills",
            "agentId": .string(agentId),
            "skills": [
                self.skill("github", "GitHub CLI for issues, PRs, CI/check logs, comments, reviews, releases, repos, and gh api queries.",
                           emoji: "🐙", requires: ["gh"], install: [self.brew("Install GitHub CLI (brew)", ["gh"])]),
                self.skill("weather", "Current weather and forecasts with web_fetch, falling back to wttr.in curl.",
                           emoji: "☔", install: [self.brew("Install curl (brew)", ["curl"])]),
                self.skill("tmux", "Remote-control tmux sessions for interactive CLIs by sending keystrokes and scraping pane output.",
                           emoji: "🧵", requires: ["tmux"], install: [self.brew("Install tmux (brew)", ["tmux"])]),
                self.skill(self.missingSkill, "Summarize or transcribe URLs, YouTube/videos, podcasts, articles, PDFs, and local files.",
                           emoji: "🧾", requires: ["summarize"], missing: ["summarize"],
                           install: [self.brew("Install summarize (brew)", ["summarize"])]),
                self.skill("apple-notes", "Manage Apple Notes via the memo CLI on macOS.", emoji: "📝",
                           requires: ["memo"], missing: ["memo"], os: ["darwin"], missingOS: ["darwin"]),
            ],
        ]
    }

    // MARK: WhatsApp QR login

    private static func webLoginChannel(_ params: JSONValue) throws {
        guard let raw = params["channel"] else { return }
        let id = raw.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if id == "whatsapp" || id == "wa" { return }
        if Self.setupChannelMeta.contains(where: { $0.id == id }) {
            throw Self.invalid("web login is not supported by provider \(id)")
        }
        throw Self.invalid("web login provider is not available")
    }

    private func webLoginStart(force: Bool) -> JSONValue {
        if self.setup.whatsappLinked, !force {
            return ["message": "WhatsApp is already linked (+15550100). Say “relink” if you want a fresh QR."]
        }
        if let login = self.setup.login, !force {
            return ["qrDataUrl": .string(login.qrDataUrl), "message": "QR already active. Scan it in WhatsApp → Linked Devices."]
        }
        if force {
            self.setup.whatsappLinked = false
            self.setup.whatsappLinkedAt = nil
        }
        let id = UUID().uuidString
        let qr = Self.qrDataUrl(seed: "\(id):1")
        self.setup.login = (id, 1, 0, qr)
        return ["qrDataUrl": .string(qr), "message": "Scan this QR in WhatsApp → Linked Devices."]
    }

    /// First wait refreshes the QR, the next one links, like someone scanning a moment later.
    private func webLoginWait(timeoutMs: Int) async throws -> JSONValue {
        guard let started = self.setup.login else {
            return ["connected": false, "message": "No active WhatsApp login in progress."]
        }
        try await Task.sleep(for: .milliseconds(max(0, min(Self.webLoginWaitMs, timeoutMs))))
        guard var login = self.setup.login, login.id == started.id else {
            return ["connected": false, "message": "WhatsApp login was replaced by a newer request."]
        }
        if timeoutMs < Self.webLoginWaitMs {
            return ["connected": false, "message": "Still waiting for the QR scan. Let me know when you’ve scanned it."]
        }
        login.waits += 1
        if login.waits == 1 {
            login.qrSeq += 1
            login.qrDataUrl = Self.qrDataUrl(seed: "\(login.id):\(login.qrSeq)")
            self.setup.login = login
            return ["connected": false, "qrDataUrl": .string(login.qrDataUrl),
                    "message": "QR refreshed. Scan the latest code in WhatsApp → Linked Devices."]
        }
        self.setup.login = nil
        self.setup.whatsappLinked = true
        self.setup.whatsappLinkedAt = Self.now().double
        self.emitHealth()
        return ["connected": true, "message": "✅ Linked! WhatsApp is ready."]
    }

    /// A QR-looking PNG (finder squares plus noise from `seed`), as a `data:` URL.
    static func qrDataUrl(seed: String) -> String {
        let modules = 25, quiet = 2, scale = 6
        let bits = Array(SHA256.hash(data: Data(seed.utf8)))
        func finder(_ x: Int, _ y: Int) -> Bool? {
            for (ox, oy) in [(0, 0), (modules - 7, 0), (0, modules - 7)] {
                let (dx, dy) = (x - ox, y - oy)
                if (0..<7).contains(dx), (0..<7).contains(dy) {
                    return max(abs(dx - 3), abs(dy - 3)) != 2
                }
            }
            return nil
        }
        func dark(_ x: Int, _ y: Int) -> Bool {
            if let f = finder(x, y) { return f }
            let i = y * modules + x
            return (bits[i % bits.count] >> (i % 8)) & 1 == 1
        }
        let size = (modules + quiet * 2) * scale
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return "data:image/png;base64," }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(gray: 0, alpha: 1)
        for y in 0..<modules {
            for x in 0..<modules where dark(x, y) {
                context.fill(CGRect(x: (x + quiet) * scale, y: size - (y + quiet + 1) * scale, width: scale, height: scale))
            }
        }
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return "data:image/png;base64," }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return "data:image/png;base64,\((data as Data).base64EncodedString())"
    }

    // MARK: Helpers

    private static func invalid(_ message: String) -> GatewayError {
        GatewayError.rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }

    private static func closedParams(_ params: JSONValue, _ allowed: Set<String>, _ method: String) throws {
        guard let object = params.object else {
            if case .null = params { return }
            throw Self.invalid("invalid \(method) params: must be object")
        }
        if let extra = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Self.invalid("invalid \(method) params: must NOT have additional properties (\(extra))")
        }
    }
}
