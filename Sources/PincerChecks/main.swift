import Foundation
import PincerKit

// Self-checks that run without XCTest (unavailable with Command Line Tools only).
//   swift run PincerChecks                  → unit checks
//   swift run PincerChecks --live URL TOKEN → end-to-end against a (mock) Gateway
// Run with PINCER_KEYCHAIN=memory so nothing touches the real Keychain.

var failures = 0
var passes = 0

// Drafts go to a scratch folder so checks never touch the real ones.
let draftsRoot = FileManager.default.temporaryDirectory.appending(path: "pincer-checks-drafts-\(UUID().uuidString)")
setenv("PINCER_DRAFTS_DIR", draftsRoot.path(percentEncoded: false), 1)

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ label: String, line: UInt = #line) {
    if condition() {
        passes += 1
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)  (line \(line))")
    }
}

func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

print("Payload & identity")
check(
    DeviceAuthPayload.v2(deviceId: "d", clientId: "openclaw-macos", clientMode: "ui", role: "operator",
                         scopes: ["operator.read", "operator.write"], signedAtMs: 42, token: nil, nonce: "n")
        == "v2|d|openclaw-macos|ui|operator|operator.read,operator.write|42||n",
    "v2 payload layout, empty token")
let identity = DeviceIdentity.loadOrCreate()
check(identity.deviceId.count == 64, "deviceId is sha256 hex")
check(DeviceIdentity.loadOrCreate().deviceId == identity.deviceId, "identity persists")
check(!identity.publicKeyBase64Url.contains("=") && !identity.publicKeyBase64Url.contains("+"), "public key is base64url")

print("URL policy")
func resolves(_ url: String) -> String? {
    try? GatewayProfile(name: "t", url: url, authMode: .token).resolvedURL().absoluteString
}
check(resolves("home.tail1234.ts.net") == "wss://home.tail1234.ts.net", "bare .ts.net → wss")
check(resolves("100.101.102.103:18789") == "ws://100.101.102.103:18789", "tailnet IP → ws")
check(resolves("ws://127.0.0.1:18789") != nil, "loopback ws allowed")
check(resolves("ws://192.168.1.5:18789") != nil, "LAN ws allowed")
check(resolves("ws://example.com") == nil, "public ws rejected")
check(resolves("wss://example.com") != nil, "public wss allowed")
check(resolves("https://home.tail1234.ts.net") == "wss://home.tail1234.ts.net", "https → wss")
check(resolves("ftp://x") == nil, "other schemes rejected")

print("Session rows")
let row = SessionRow(json("""
{"key":"agent:research:dashboard:x","label":"Papers","pinned":true,"unread":true,"channel":"discord",
 "parentSessionKey":"agent:research:main","lastActivityAt":1700000000000,"updatedAt":1600000000000}
"""))!
check(row.agentId == "research", "agentId from key")
check(row.title == "Papers" && row.isPinned && row.isUnread, "title/pinned/unread")
check(row.parentKey == "agent:research:main", "parent key → thread")
check(row.originLabel == "Discord", "origin label")
check(row.activityMs == 1_700_000_000_000, "activity uses latest timestamp")
check(SessionRow(json(#"{"label":"no key"}"#)) == nil, "rows without key rejected")
do {
    let withPreview = SessionRow(json(#"{"key":"p","lastMessagePreview":"Found 3 rentals"}"#))!
    let bareUpdate = SessionRow(json(#"{"key":"p","pinned":true}"#))!
    let newer = SessionRow(json(#"{"key":"p","lastMessagePreview":"Booked a viewing"}"#))!
    check(bareUpdate.keepingPreview(of: withPreview).preview == "Found 3 rentals", "partial row keeps previous preview")
    check(bareUpdate.keepingPreview(of: withPreview).isPinned, "partial row keeps its own fields")
    check(newer.keepingPreview(of: withPreview).preview == "Booked a viewing", "new preview replaces old")
}

print("Discord channels")
let discord = SessionRow(json(##"{"key":"agent:main:discord:channel:1300000000000000001","displayName":"1100000000000000001 #finances","channel":"discord","chatType":"channel","groupChannel":"#finances","space":"1100000000000000001","origin":{"label":"Home Lab #finances channel id:1300000000000000001","provider":"discord","chatType":"channel"}}"##))!
check(discord.title == "finances", "guild-id prefix dropped from channel title (got \(discord.title))")
check(discord.server?.id == "1100000000000000001" && discord.server?.name == "Home Lab", "server id and name from origin")
let bare = SessionRow(json(#"{"key":"k","displayName":"1100000000000000001 #gyms","label":"1100000000000000001 #gyms","chatType":"channel","channel":"discord","space":"1100000000000000001"}"#))!
check(bare.title == "gyms", "generated label is cleaned (got \(bare.title))")
check(bare.server?.name == nil && bare.server?.displayName == "Discord", "unnamed server fallback")
let renamed = SessionRow(json(##"{"key":"k","label":"Money talk","groupChannel":"#finances","chatType":"channel","channel":"discord","space":"1"}"##))!
check(renamed.title == "Money talk", "user label wins")
let thread = SessionRow(json(##"{"key":"agent:main:discord:channel:1:thread:2","derivedTitle":"Todoist read for daily priorities","groupChannel":"#daily-tasks","chatType":"channel","channel":"discord","space":"1"}"##))!
check(thread.title == "Todoist read for daily priorities" && thread.isChannelThread, "Discord thread keeps its own title")
let direct = SessionRow(json(#"{"key":"agent:main:discord:direct:9","displayName":"Sam","chatType":"direct","channel":"discord"}"#))!
check(direct.server == nil && direct.title == "Sam", "DMs are not server channels")
let sub = SessionRow(json(#"{"key":"agent:main:subagent:1","spawnedBy":"agent:main:cron:job1:run:r1","label":"Uptown rentals","channel":"discord"}"#))!
check(sub.isSubagent && !discord.isSubagent && !row.isSubagent, "subagent detection by key")
check(sub.parentCandidates == ["agent:main:cron:job1:run:r1", "agent:main:cron:job1"], "automation run subagents fall back to the automation")
check(sub.server == nil, "subagents are not server channels")
let webReply = SessionRow(json(##"{"key":"agent:main:discord:channel:5","kind":"group","chatType":"direct","channel":"discord","groupChannel":"#gyms","space":"1","origin":{"provider":"webchat"}}"##))!
check(webReply.server?.provider == "discord" && webReply.title == "gyms", "channel stays in server after a web UI reply")
let slash = SessionRow(json(#"{"key":"agent:main:discord:slash:3","kind":"group","displayName":"1100000000000000001","channel":"discord","space":"1100000000000000001"}"#))!
check(slash.title == "Slash commands", "slash session titled (got \(slash.title))")
let newChat = SessionRow(json(#"{"key":"agent:main:dashboard:1","parentSessionKey":"agent:main:main","createdVia":"operator","spawnDepth":0}"#))!
check(newChat.isStandaloneChat && newChat.parentCandidates.isEmpty, "new chats started from main aren't nested under it")
let branch = SessionRow(json(#"{"key":"agent:main:dashboard:2","parentSessionKey":"agent:main:main","createdVia":"operator","forkedFromParent":true}"#))!
check(!branch.isStandaloneChat && branch.parentCandidates == ["agent:main:main"], "forks stay nested")
let channelChild = SessionRow(json(#"{"key":"agent:main:dashboard:3","parentSessionKey":"agent:main:discord:channel:5","createdVia":"operator"}"#))!
check(!channelChild.isStandaloneChat, "chats branched from a channel stay nested")
let automation = SessionRow(json(#"{"key":"agent:main:cron:job1","label":"Automation: Daily budget summary"}"#))!
check(automation.isAutomation && automation.title == "Daily budget summary", "automation title")

print("Media directives")
let media = MediaDirectives.extract(from: "Here's a real photograph of two mallard ducks.\nMEDIA:https://upload.wikimedia.org/wikipedia/commons/b/bf/Anas_platyrhynchos_male_female_quadrat.jpg\nPhoto: Richard Bartz / Wikimedia Commons.")
check(media.images.first?.url == "https://upload.wikimedia.org/wikipedia/commons/b/bf/Anas_platyrhynchos_male_female_quadrat.jpg", "MEDIA: URL becomes an image")
check(media.text == "Here's a real photograph of two mallard ducks.\nPhoto: Richard Bartz / Wikimedia Commons.", "directive line removed from text (got \(media.text))")
check(media.images.first?.alt == "Anas_platyrhynchos_male_female_quadrat.jpg", "image named after file")
let local = MediaDirectives.extract(from: "MEDIA: `/tmp/chart.png`\nMEDIA:~/report.pdf")
check(local.images.first?.url == "/tmp/chart.png" && local.files == [FileRef(name: "report.pdf", url: "~/report.pdf")], "local image + non-image file")
let fenced = MediaDirectives.extract(from: "```\nMEDIA:https://x.example/a.png\n```")
check(fenced.images.isEmpty, "directives inside code fences stay text")
check(MediaDirectives.withoutPartialDirective("Here:\nMEDIA:https://upl") == "Here:\n", "partial streamed directive hidden")
check(MediaDirectives.withoutPartialDirective("Done") == "Done", "normal streaming text untouched")
let svgMedia = MediaDirectives.extract(from: "Done.\nMEDIA:output/wolf.svg")
check(svgMedia.images.count == 1 && svgMedia.files.isEmpty, "SVG directive renders as an image")
let svgAttachment = ChatItem(json(#"{"role":"assistant","content":[{"type":"attachment","attachment":{"url":"output/wolf.svg","kind":"image","label":"wolf.svg","mimeType":"image/svg+xml"}}],"__openclaw":{"id":"sa1"}}"#), fallbackIndex: 0)
if case let .image(ref)? = svgAttachment?.blocks.first { check(ref.url == "output/wolf.svg" && ref.alt == "wolf.svg", "attachment block SVG is an image") } else { check(false, "attachment block SVG is an image") }
let codeFile = ChatItem(json(#"{"role":"assistant","content":[{"type":"attachment","attachment":{"url":"output/app.py","kind":"document","label":"app.py"}}],"__openclaw":{"id":"f1"}}"#), fallbackIndex: 0)
if case let .file(file)? = codeFile?.blocks.first {
    check(file.url == "output/app.py" && file.isDownloadable && file.isText && file.language == "py", "code attachment keeps its source and previews")
} else { check(false, "code attachment keeps its source and previews") }
check(FileRef(name: "data", mimeType: "application/json").isText && !FileRef(name: "a.pdf", mimeType: "application/pdf").isText
      && FileRef(name: "Dockerfile").isText && !FileRef(name: "a.zip").isText, "text files recognized")
let svgData = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"><rect width="400" height="200" fill="red"/></svg>"#.utf8)
check(SVGRasterizer.isSVG(svgData) && !SVGRasterizer.isSVG(Data("<html><svg></svg>".utf8)), "SVG sniffing")
check(SVGRasterizer.intrinsicSize(svgData) == CGSize(width: 400, height: 200), "SVG size from viewBox")
check(SVGRasterizer.intrinsicSize(Data(#"<svg width="120px" height='60' viewBox="0 0 10 10">"#.utf8)) == CGSize(width: 120, height: 60), "SVG size from width/height")
let svgFitted = await SVGRasterizer.rasterize(svgData, fitting: CGSize(width: 3000, height: 900))
check(svgFitted?.width == 1800 && svgFitted?.height == 900, "SVG rasterizes to fit preview bounds")
let svgImage = await SVGRasterizer.rasterize(svgData)
check(svgImage?.width == 1200 && svgImage?.height == 600, "SVG rasterizes")
let turnEntries = TranscriptBuilder.build([ChatItem(json(#"{"role":"assistant","content":[{"type":"text","text":"Duck:\nMEDIA:https://e.example/d.webp"}]}"#), fallbackIndex: 0)!])
if case let .assistant(turn) = turnEntries.first {
    check(turn.images.count == 1 && turn.body == "Duck:", "transcript turn renders MEDIA as image")
} else {
    check(false, "assistant turn built")
}

print("Transcript")
let history = json("""
[
 {"role":"user","content":[{"type":"text","text":"check disk"}],"timestamp":1,"provenance":{"sourceChannel":"discord"},"__openclaw":{"id":"m1"}},
 {"role":"assistant","content":[{"type":"thinking","thinking":"Use df."},{"type":"toolCall","id":"c1","name":"exec","arguments":{"command":"df -h"}}],"__openclaw":{"id":"m2"}},
 {"role":"toolResult","toolCallId":"c1","toolName":"exec","content":[{"type":"text","text":"/ 50%"}],"__openclaw":{"id":"m3"}},
 {"role":"assistant","content":[{"type":"text","text":"Half full."},{"type":"image","artifactId":"a1","mimeType":"image/png","width":320,"height":200}],"__openclaw":{"id":"m4"}},
 {"role":"system","content":"ignored"},
 {"role":"user","content":"thanks","__openclaw":{"id":"m5"}}
]
""")
let items = history.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
check(items.count == 6, "parses all messages")
check(items[0].via == "Discord", "user provenance → via Discord")
let entries = TranscriptBuilder.build(items)
check(entries.count == 3, "user / assistant turn / user (got \(entries.count))")
if case let .assistant(turn) = entries[1] {
    check(turn.thinking == ["Use df."], "thinking folded into turn")
    check(turn.tools.count == 1 && turn.tools[0].result == "/ 50%", "tool call paired with result")
    check(turn.tools[0].arguments?.contains("df -h") == true, "tool arguments rendered")
    check(turn.body == "Half full.", "reply text")
    check(turn.images.first?.artifactId == "a1" && turn.images.first?.aspectRatio == 1.6, "image block")
} else {
    check(false, "second entry is an assistant turn")
}
let backToBack = json("""
[
 {"role":"assistant","content":[{"type":"text","text":"Checking."},{"type":"toolCall","id":"b1","name":"exec","arguments":{}}],"timestamp":1000,"__openclaw":{"id":"b1","runId":"r1"}},
 {"role":"toolResult","toolCallId":"b1","content":"ok","__openclaw":{"id":"b2","runId":"r1"}},
 {"role":"assistant","content":[{"type":"text","text":"Done."},{"type":"text","text":"More."}],"timestamp":2000,"__openclaw":{"id":"b3","runId":"r1"}},
 {"role":"assistant","content":[{"type":"text","text":"Daily digest"}],"timestamp":3000,"__openclaw":{"id":"b4","runId":"r2"}}
]
""")
let backToBackEntries = TranscriptBuilder.build(backToBack.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) })
check(backToBackEntries.count == 2, "a reply from another run gets its own row (got \(backToBackEntries.count))")
if case let .assistant(turn)? = backToBackEntries.first {
    check(turn.text == ["Checking.", "Done.\n\nMore."], "each assistant message stays a separate text entry")
    check(turn.textTimestamps == [Date(timeIntervalSince1970: 1000), Date(timeIntervalSince1970: 2000)], "each message keeps its own timestamp")
    check(turn.body == "Checking.\n\nDone.\n\nMore.", "reply body still joins every message")
} else {
    check(false, "back-to-back turn built")
}
check(ChatItem(json(#"{"role":"assistant","content":[],"errorMessage":"boom"}"#), fallbackIndex: 0)?.isError == true, "error-only assistant message")
let spawn = ToolActivity(id: "t", name: "sessions_spawn", arguments: #"{"label":"Find rentals","task":"x"}"#, result: nil, isError: false, isRunning: false)
check(spawn.spawnLabel == "Find rentals" && spawn.summary == nil, "spawn label derived once")
var sent = ToolActivity(id: "t2", name: "sessions_send", arguments: #"{"command":"ls"}"#, result: nil, isError: false, isRunning: false)
sent.result = #"{"sessionKey":"agent:main:subagent:1f2e-9a"}"#
check(sent.summary == "ls" && sent.spawnedSessionKey == "agent:main:subagent:1f2e-9a", "subagent key found in tool result")
check(ChatItem(json(#"{"role":"user","content":"hi","__openclaw":{"id":"abc"}}"#), fallbackIndex: 7)?.id == "abc", "row id is stable across pages")
check(ChatItem(json(#"{"role":"assistant","content":"long\n...(truncated)...","__openclaw":{"id":"t1","truncated":true}}"#), fallbackIndex: 0)?.isCapped == true, "capped assistant message flagged")
check(ChatItem(json(#"{"role":"assistant","content":"literal ...(truncated)...","__openclaw":{"id":"t2"}}"#), fallbackIndex: 0)?.isCapped == false, "sentinel text alone isn't a cap")
check(ChatItem(json(#"{"role":"toolResult","content":"x","__openclaw":{"id":"t3","truncated":true}}"#), fallbackIndex: 0)?.isCapped == false, "only assistant/pending messages are recoverable")
let uploaded = ChatItem(json(#"{"role":"user","content":[{"type":"text","text":"look"}],"__openclaw":{"id":"u1","media":[{"path":"media://inbound/abc.png","contentType":"image/png","fileName":"Pasted Image.png","origin":"paste"},{"path":"media://inbound/doc.pdf","contentType":"application/pdf","fileName":"doc.pdf"}]}}"#), fallbackIndex: 0)
if case let .image(ref)? = uploaded?.blocks.dropFirst().first, case let .file(file)? = uploaded?.blocks.last {
    check(uploaded?.blocks.count == 3 && ref.url == "media://inbound/abc.png" && ref.alt == "Pasted Image.png" && file.name == "doc.pdf" && file.url == "media://inbound/doc.pdf", "uploaded media facts show on user messages")
} else {
    check(false, "uploaded media facts show on user messages")
}
check(ChatItem(json(#"{"role":"user","content":[],"__openclaw":{"id":"u2","media":[{"path":"media://inbound/x.jpg","kind":"image"}]}}"#), fallbackIndex: 0)?.blocks.count == 1, "image-only upload keeps its row")
let stripped = json(##"""
[
 {"role":"assistant","content":[{"type":"thinking","thinking":""},{"type":"toolCall","id":"v1","name":"view_image","arguments":{"url":"https://x/y.jpg"}}],"__openclaw":{"id":"s1"}},
 {"role":"toolResult","toolCallId":"v1","toolName":"view_image","content":[{"type":"text","text":"Loaded 1 image"},{"type":"image","mimeType":"image/jpeg","bytes":226618,"omitted":true}],"__openclaw":{"id":"s2"}}
]
"""##)
if case let .assistant(turn) = TranscriptBuilder.build(stripped.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }).first {
    check(turn.images.isEmpty, "omitted tool-result images don't leave blank slots")
    check(turn.thinking.isEmpty, "empty thinking blocks are hidden")
} else {
    check(false, "omitted-image turn built")
}

print("Models")
check(ModelRef.qualified("claude-opus-4-8", provider: "anthropic") == "anthropic/claude-opus-4-8", "model ref qualified with provider")
check(ModelRef.qualified("anthropic/claude-opus-4-8", provider: "anthropic") == "anthropic/claude-opus-4-8", "already-qualified ref kept")
check(ModelRef.shortName("openrouter/meta/llama-4") == "llama-4" && ModelRef.shortName("gpt-5") == "gpt-5", "short model name")
let choice = ModelChoice(json(#"{"id":"gpt-5.6-sol","name":"GPT-5.6 Sol","provider":"openai","available":false}"#))
check(choice?.ref == "openai/gpt-5.6-sol" && choice?.isAvailable == false && choice?.displayName == "GPT-5.6 Sol", "models.list entry")
let modelRow = SessionRow(json(#"{"key":"k","model":"claude-sonnet-5","modelProvider":"anthropic","modelOverrideSource":"user"}"#))!
check(modelRow.modelRef == "anthropic/claude-sonnet-5" && modelRow.modelOverrideSource == "user", "session row model ref")
let attributed = json(#"""
[
 {"role":"user","content":"hi","__openclaw":{"id":"x1"}},
 {"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","content":[{"type":"toolCall","id":"t1","name":"exec","arguments":{}}],"__openclaw":{"id":"x2"}},
 {"role":"toolResult","toolCallId":"t1","content":"ok","__openclaw":{"id":"x3"}},
 {"role":"assistant","provider":"openai","model":"gpt-5.6-sol","content":"done","__openclaw":{"id":"x4"}},
 {"role":"user","content":"again","__openclaw":{"id":"x5"}},
 {"role":"assistant","model":"gateway-injected","content":"notice","__openclaw":{"id":"x6"}}
]
"""#).array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
check(attributed[1].modelRef == "anthropic/claude-opus-4-8" && attributed[0].model == nil, "assistant messages carry their model")
let attributedTurns = TranscriptBuilder.build(attributed).compactMap { entry -> AssistantTurn? in
    if case let .assistant(turn) = entry { return turn }
    return nil
}
check(attributedTurns.first?.modelRef == "openai/gpt-5.6-sol" && attributedTurns.first?.modelName == "gpt-5.6-sol", "turn takes its latest model")
check(attributedTurns.first?.textModelNames.compactMap(\.self).last == "gpt-5.6-sol", "each message keeps its own model")
check(attributedTurns.count == 2 && attributedTurns.last?.model == nil, "gateway-injected messages have no model")
let roundTrip = try? JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(attributed[1]))
check(roundTrip?.modelRef == "anthropic/claude-opus-4-8", "model survives the transcript cache")

print("Exec approvals")
let approval = ExecApproval(json(#"{"id":"ap1","request":{"command":"rm -rf build","cwd":"/p","sessionKey":"agent:main:main"},"expiresAtMs":1}"#))
check(approval?.id == "ap1" && approval?.command == "rm -rf build" && approval?.cwd == "/p", "approval payload")

print("Gateway config schema")
let configSchema = ConfigSchema(response: json(#"""
{"version":"2026.9.1","schema":{"type":"object","definitions":{"port":{"type":"integer","minimum":1,"maximum":65535}},
 "properties":{
  "gateway":{"type":"object","required":["port"],"properties":{
    "port":{"$ref":"#/definitions/port"},
    "bind":{"anyOf":[{"const":"loopback"},{"const":"lan"},{"const":"tailnet"}]},
    "auth":{"type":"object","properties":{"mode":{"type":"string","enum":["token","password","none"]},
      "token":{"anyOf":[{"type":"string"},{"type":"object","properties":{"source":{"type":"string"},"id":{"type":"string"}}}]}}}}},
  "agents":{"type":"object","properties":{"defaults":{"allOf":[{"type":"object","properties":{"model":{"type":"string","minLength":3}}},
    {"properties":{"thinking":{"type":"boolean"}}}]}}},
  "tools":{"type":"object","properties":{"allow":{"type":"array","items":{"type":"string"}},
    "rules":{"type":"array","items":{"type":"object"}}}},
  "plugins":{"type":"object","properties":{"entries":{"type":"object","additionalProperties":{"type":"object",
    "properties":{"enabled":{"type":"boolean"},"config":{"type":"object","additionalProperties":{}}}}}}}
 }},
 "uiHints":{"gateway":{"label":"Gateway","order":1},"gateway.auth.token":{"sensitive":true,"label":"Token"},
  "gateway.port":{"help":"Port the Gateway listens on.","order":1},
  "plugins.entries.*.config.apiKey":{"sensitive":true,"label":"API key"}}}
"""#))
check(configSchema.version == "2026.9.1", "schema version")
let sampleConfig = json(#"{"gateway":{"port":18789,"bind":"tailnet","auth":{"mode":"token","token":"__OPENCLAW_REDACTED__"}},"plugins":{"entries":{"weather":{"enabled":true,"config":{"apiKey":"__OPENCLAW_REDACTED__","units":"metric"}}}}}"#)
let topFields = configSchema.fields(at: [], value: sampleConfig)
check(topFields.first?.label == "Gateway" && topFields.allSatisfy { $0.kind == .object }, "top-level sections, ordered by hint (\(topFields.map(\.label)))")
let gatewayFields = configSchema.fields(at: ["gateway"], value: sampleConfig["gateway"])
let port = gatewayFields.first { $0.key == "port" }
check(port?.kind == .integer && port?.isRequired == true && port?.maximum == 65535, "$ref resolved: required integer with bounds")
check(port?.help == "Port the Gateway listens on." && gatewayFields.first?.key == "port", "hint help and order")
check(gatewayFields.first { $0.key == "bind" }?.kind == .choice(["loopback", "lan", "tailnet"]), "const union → choice")
let authFields = configSchema.fields(at: ["gateway", "auth"], value: sampleConfig["gateway"]?["auth"])
check(authFields.first { $0.key == "mode" }?.kind == .choice(["token", "password", "none"]), "enum → choice")
check(authFields.first { $0.key == "token" }?.kind == .secret, "sensitive hint → secret field")
let tokenRefField = configSchema.field(at: ["gateway", "auth", "token"], value: json(#"{"source":"env","id":"TOKEN"}"#))
check(tokenRefField?.kind == .secret && tokenRefField?.allowsSecretRef == true, "SecretRef-capable secret stays a secret field")
check(authFields.first { $0.key == "token" }?.allowsSecretRef == true, "schema with a ref branch allows SecretRefs")
check(SecretRef(json(#"{"source":"env","provider":"default","id":"TOKEN"}"#)) == SecretRef(source: .env, id: "TOKEN"), "SecretRef parsed")
check(SecretRef(source: .file, id: "/k").json == json(#"{"source":"file","provider":"default","id":"/k"}"#), "SecretRef JSON")
check(tokenRefField?.validate(json(#"{"source":"env","id":"TOKEN"}"#)) == nil, "SecretRef passes validation")
let defaults = configSchema.fields(at: ["agents", "defaults"], value: nil)
check(Set(defaults.map(\.key)) == ["model", "thinking"], "allOf properties merged")
check(defaults.first { $0.key == "model" }?.validate("ab") != nil, "minLength enforced")
let toolFields = configSchema.fields(at: ["tools"], value: nil)
check(toolFields.first { $0.key == "allow" }?.kind == .list && toolFields.first { $0.key == "rules" }?.kind == .json,
      "string arrays are lists, object arrays JSON")
let pluginConfig = configSchema.fields(at: ["plugins", "entries", "weather", "config"],
                                       value: sampleConfig.value(at: ["plugins", "entries", "weather", "config"]))
check(pluginConfig.map(\.key) == ["apiKey", "units"], "map-like plugin config lists existing keys")
check(pluginConfig.first?.kind == .secret && pluginConfig.first?.label == "API key", "wildcard hint matches plugin id")
check(configSchema.fields(at: ["plugins"], value: nil).first { $0.key == "entries" }?.isMap == true, "additionalProperties object is a map")

print("Gateway config values")
if let port {
    check(port.validate(nil) == "Port is required.", "required field")
    check(port.validate(.number(70000)) != nil && port.validate(.number(8080)) == nil, "range check")
    check((try? port.value(fromText: "abc")) == nil, "non-numeric input rejected")
    check((try? port.value(fromText: " 8080 ")) == .number(8080), "integer parsed")
    check(port.text(for: .number(18789)) == "18789", "integer shown without decimals")
}
let bind = gatewayFields.first { $0.key == "bind" }!
check(bind.validate("public") != nil && bind.validate("lan") == nil, "choice validated")
let list = toolFields.first { $0.key == "allow" }!
check((try? list.value(fromText: "exec\n read \n\n")) == json(#"["exec","read"]"#), "list input split by line")
check(list.text(for: json(#"["a","b"]"#)) == "a\nb", "list shown one per line")
check((try? toolFields.first { $0.key == "rules" }!.value(fromText: "{nope")) == nil, "invalid JSON rejected")
check(authFields.first { $0.key == "token" }?.validate(.string(JSONValue.redactedSentinel)) == nil, "redacted secret passes")
check(sampleConfig.value(at: ["gateway", "auth", "mode"]) == "token", "value(at:)")

var edits = ConfigEdits(base: sampleConfig)
edits.set(["gateway", "port"], .number(18789))
check(!edits.hasChanges && edits.patch == nil, "setting the same value is not a change")
edits.set(["gateway", "port"], .number(9000))
edits.set(["gateway", "bind"], nil)
check(edits.patch == json(#"{"gateway":{"port":9000,"bind":null}}"#), "edits → merge patch with removal")
check(edits.value(at: ["gateway", "port"]) == 9000 && edits.value(at: ["gateway", "bind"]) == nil
      && edits.value(at: ["gateway", "auth", "mode"]) == "token", "edited values read through")
check(edits.changes.map(\.id) == ["gateway.bind", "gateway.port"] && edits.changeCount(under: ["gateway"]) == 2
      && edits.changeCount(under: ["plugins"]) == 0, "leaf changes counted by section")
check(edits.isChanged(["gateway"]) && edits.isChanged(["gateway", "port"]) && !edits.isChanged(["gateway", "auth"]), "isChanged")
edits.set(["gateway", "port"], .number(18789))
check(edits.patch == json(#"{"gateway":{"bind":null}}"#), "setting the loaded value drops the edit")
edits.revert(["gateway"])
check(!edits.hasChanges, "revert a whole section")
edits.set(["channels", "entries", "discord"], .object([:]))
edits.set(["channels", "entries", "discord", "token"], "abc")
check(edits.patch == json(#"{"channels":{"entries":{"discord":{"token":"abc"}}}}"#), "editing inside a new entry")
edits.discardAll()
// JSONValue is ExpressibleByNilLiteral; absent must be Optional.none, not `.null`.
func isAbsent(_ value: JSONValue?) -> Bool { if case .none = value { true } else { false } }
check(isAbsent(edits.value(at: ["agents", "entries"])) && isAbsent(edits.value(at: ["gateway", "nope"])),
      "missing paths read as absent")
edits.set(["gateway", "bind"], "lan")
edits.set(["gateway", "bind"], nil)
check(isAbsent(edits.value(at: ["gateway", "bind"])), "a removed key reads as absent")
edits.discardAll()
check(isAbsent(edits.patch), "no patch without changes")

var arrayEdits = ConfigEdits(base: json(#"{"tools":{"allow":["a","b"],"deny":["x"]},"old":{"list":[1],"keep":true}}"#))
arrayEdits.set(["tools", "allow"], json(#"["a"]"#))
arrayEdits.set(["old"], nil)
check(arrayEdits.replacePaths == ["old.list", "tools.allow"], "replacePaths lists changed and deleted arrays (\(arrayEdits.replacePaths))")

var rebased = ConfigEdits(base: json(#"{"a":1,"b":1,"c":1}"#))
rebased.set(["a"], 2)
rebased.set(["b"], 2)
let conflicts = rebased.rebase(onto: json(#"{"a":1,"b":3,"c":5}"#))
check(conflicts.map(\.id) == ["b"] && conflicts.first?.theirs == 3 && conflicts.first?.mine == 2, "rebase reports real conflicts only")
check(rebased.current == json(#"{"a":2,"b":2,"c":5}"#), "rebase keeps edits over the newer config")
check(JSONValue.mergeDiff(from: json(#"{"a":{"b":1,"c":2},"d":[1]}"#), to: json(#"{"a":{"b":1},"d":[1,2],"e":true}"#))
      == json(#"{"a":{"c":null},"d":[1,2],"e":true}"#), "mergeDiff")

let tiered = ConfigSchema(response: json(#"""
{"schema":{"type":"object","properties":{"gateway":{"type":"object","properties":{"port":{"type":"integer"},
  "tls":{"type":"object","properties":{"cert":{"type":"string"}}},"reload":{"type":"string"}}}}},
 "uiHints":{"gateway":{"advanced":false},"gateway.tls":{"advanced":true},"gateway.tls.cert":{"advanced":false}}}
"""#))
check(tiered.hasTiers && !tiered.isAdvanced(["gateway", "port"]) && tiered.isAdvanced(["gateway", "tls"])
      && !tiered.isAdvanced(["gateway", "tls", "cert"]), "advanced tiers inherit from the nearest hint")
check(tiered.isAdvanced(["other"]) && !configSchema.isAdvanced(["other"]), "unhinted paths are advanced only with tiers")
check(tiered.searchIndex(config: .object([:])).contains { $0.path == ["gateway", "tls", "cert"] }, "search index reaches nested fields")

check(SettingsCatalog.location(for: ["gateway", "port"]).destination == .page("gateway"), "curated location")
check(SettingsCatalog.location(for: ["plugins", "entries", "weather", "config", "apiKey"])
      == SettingsLocation(destination: .plugins, routes: [.plugin("weather")], focus: ["plugins", "entries", "weather", "config", "apiKey"]),
      "plugin setting opens its plugin")
check(SettingsCatalog.location(for: ["zzz", "q"]).destination == .allSettings, "unknown settings fall back to All Settings")
let merged = sampleConfig.applyingMergePatch(json(#"{"gateway":{"port":1,"auth":null},"new":{"a":[1]}}"#))
check(merged["gateway"]?["port"] == 1 && merged["gateway"]?["auth"] == nil && merged["gateway"]?["bind"] == "tailnet"
      && merged["new"]?["a"] == json("[1]"), "RFC 7386 merge")
check(JSONValue.mergePatch(setting: false, at: ["plugins", "entries", "x", "enabled"])
      == json(#"{"plugins":{"entries":{"x":{"enabled":false}}}}"#), "nested merge patch")

print("Gateway config feedback")
let rejected = GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid config: gateway.port: too big", details: json(#"""
{"issues":[{"path":"gateway.port","message":"Number must be less than or equal to 65535"},{"path":["plugins","entries","x"],"message":"unknown plugin","fixHint":"install it"}]}
"""#))
let issues = ConfigIssue.from(rejected)
check(issues.count == 2 && issues[0].path == "gateway.port" && issues[1].path == "plugins.entries.x" && issues[1].fixHint == "install it",
      "validation issues parsed from error details")
check(ConfigIssue.from(GatewayError.rpc(code: "INVALID_REQUEST", message: "boom", details: nil)).first?.message == "boom",
      "error without issues keeps its message")
check(ConfigApplyOutcome(configWrite: json(#"{"ok":true,"noop":true}"#)) == .noChange, "noop patch")
check(ConfigApplyOutcome(configWrite: json(#"{"ok":true,"restart":{"delayMs":2000}}"#)) == .restarting, "restart scheduled")
check(ConfigApplyOutcome(configWrite: json(#"{"ok":true,"hash":"h"}"#)) == .applied, "hot-applied")
check(ConfigApplyOutcome(pluginChange: json(#"{"ok":true,"restartRequired":true}"#)) == .restarting, "plugin restart")

let plugin = PluginInfo(json(#"{"id":"weather","name":"Weather","installed":true,"enabled":true,"state":"needs-setup","origin":"clawhub","runtime":{"state":"disabled"}}"#))
check(plugin?.needsSetup == true && plugin?.statusLabel == "Needs setup" && plugin?.removable == true, "plugin entry")
check(PluginInfo(json(#"{"id":"b","name":"B","installed":true,"enabled":false,"state":"disabled","origin":"bundled"}"#))?.removable == false,
      "bundled plugins aren't removable by default")
let credential = PluginCredential(json(#"{"path":["plugins","entries","weather","config","apiKey"],"label":"API key","envVars":["WEATHER_KEY"],"signupUrl":"http://x","requiresCredential":true}"#))
check(credential?.path.last == "apiKey" && credential?.isRequired == true && credential?.signupURL == nil, "plugin credential (non-https signup dropped)")
check(PluginCredential(json(#"{"path":["a","b",0,"c","d"],"label":"x","envVars":[]}"#)) == nil, "array credential paths skipped")

print("Progress card")
let card = ProgressCard(json("""
{"sessionKey":"agent:main:main","revision":5,"updatedAt":1700000000000,
 "markdown":"**Three-step task: wolf SVG**\\n\\nI'll update the card between phases.",
 "steps":[{"step":"Plan the composition","status":"completed"},
          {"step":"Create the SVG","status":"in_progress"},
          {"step":"Validate","status":"pending"},
          {"step":"  ","status":"pending"},
          {"step":"Bad","status":"done"}]}
"""))
check(card?.revision == 5 && card?.steps.count == 3, "card parses, drops blank/unknown steps")
check(card?.completedCount == 1 && card?.currentStep?.text == "Create the SVG" && card?.currentPosition == 2,
      "current step is the in-progress one")
check(card?.markdownSummary == "Three-step task: wolf SVG", "markdown summary strips emphasis")
check(card?.isComplete == false, "incomplete card")
check(ProgressCard(json(#"{"revision":1,"updatedAt":1,"markdown":"  "}"#)) == nil, "empty card is nil")
let htmlCard = ProgressCard(json(#"""
{"revision":1,"markdown":"<progress aria-label=\"Snap · 0/5\" value=\"0\" max=\"5\"></progress>\n**System health** (a < b)",
 "steps":[{"step":"Disk","status":"in_progress"}]}
"""#))
check(htmlCard?.markdown == "**System health** (a < b)" && htmlCard?.markdownSummary == "System health (a < b)",
      "markdown drops raw HTML tags")
check(ProgressCard(.null) == nil, "null card is nil")
let done = ProgressCard(json(#"{"revision":2,"updatedAt":1,"steps":[{"step":"A","status":"completed"}]}"#))
check(done?.isComplete == true && done?.currentStep?.text == "A", "complete card keeps last step current")
let legacy = ProgressCard(legacyPlan: json("""
{"phase":"update","explanation":"Why","steps":["First",{"step":"Second","status":"in_progress"},
 {"step":"Third","status":"in_progress"}]}
"""), revision: 1)
check(legacy?.steps.map(\.text) == ["First", "Second"] && legacy?.markdown == "Why",
      "legacy plan: string steps, one in-progress step")

print("Slash commands")
let catalog = SlashCommand.parse(json(#"""
{"commands":[
 {"name":"think","textAliases":["/think","/thinking","/t"],"description":"Set thinking level.","source":"native","scope":"both","acceptsArgs":true,
  "args":[{"name":"level","description":"Thinking level","type":"string","dynamic":true}]},
 {"name":"verbose","textAliases":["/verbose","/v"],"description":"Toggle verbose mode.","source":"native","scope":"both","acceptsArgs":true,
  "args":[{"name":"mode","description":"on, off, or full","type":"string","choices":[{"value":"on","label":"on"},{"value":"off","label":"off"},{"value":"full","label":"full"}]}]},
 {"name":"restart","textAliases":["/restart"],"description":"Restart OpenClaw.","source":"native","scope":"both","acceptsArgs":false},
 {"name":"reset","textAliases":["/reset"],"description":"Reset the current session.","source":"native","scope":"both","acceptsArgs":true},
 {"name":"model","textAliases":["/model"],"description":"Show or set the model.","source":"native","scope":"both","acceptsArgs":true,
  "args":[{"name":"model","description":"Model id","type":"string"}]},
 {"name":"native_only","description":"Discord menu","source":"native","scope":"native","acceptsArgs":false},
 {"name":"weather","textAliases":["/weather"],"description":"Weather lookup","source":"plugin","scope":"both","acceptsArgs":true}
]}
"""#))
check(catalog.map(\.name) == ["think", "verbose", "restart", "reset", "model", "weather"], "commands.list parsed, native-only dropped")
check(catalog[0].aliases == ["thinking", "t"] && catalog[0].args.first?.isDynamic == true, "aliases and dynamic args")
check(catalog[1].args.first?.choices.map(\.value) == ["on", "off", "full"], "static choices")
let withClear = SlashCommand.withClientCommands(catalog)
func names(_ text: String) -> [String] {
    SlashCompletion.suggestions(for: text, commands: withClear).map { suggestion in
        switch suggestion.kind {
        case let .command(command): command.name
        case let .argument(choice, _, _): choice.value
        }
    }
}
check(names("/").count == withClear.count, "bare slash lists every command")
check(names("/re") == ["restart", "reset"], "prefix match (got \(names("/re")))")
check(names("/t").first == "think", "alias exact match ranks first (got \(names("/t")))")
check(names("/cle") == ["clear"], "client /clear offered")
check(names("/verbose ") == ["on", "off", "full"] && names("/v f").first == "full", "argument choices, via alias")
check(names("/restart ").isEmpty && names("/nope x").isEmpty && names("hello /re").isEmpty, "no suggestions off-command")
check(names("/usr/bin").isEmpty && names("/re\nx").isEmpty, "paths and multi-line text ignored")
let restart = SlashCompletion.suggestions(for: "/rest", commands: withClear)[0]
check(restart.replacement == "/restart" && !restart.isComplete(for: "/rest") && restart.isComplete(for: "/restart"), "command replacement")
check(SlashCompletion.suggestions(for: "/verb", commands: withClear)[0].replacement == "/verbose ", "arg-taking command adds a space")
let models = SlashCompletion.suggestions(for: "/model op", commands: withClear) { command, index, _ in
    command.matches("model") && index == 0
        ? [SlashCommandChoice(value: "anthropic/claude", label: "Claude"), SlashCommandChoice(value: "openai/gpt", label: "GPT")]
        : []
}
check(models.map(\.replacement) == ["/model openai/gpt", "/model anthropic/claude"], "model choices from the provider (got \(models.map(\.replacement)))")
check(SlashCommand.outgoingText("/clear", commands: withClear) == "/reset", "/clear sent as /reset")
check(SlashCommand.outgoingText("/clear", commands: [SlashCommand(name: "clear", description: "server")]) == "/clear",
      "a Gateway /clear is sent as is")
check(SlashCommand.outgoingText("/clear the table", commands: withClear) == "/clear the table", "only a bare /clear is rewritten")
let byModelName = SlashCompletion.suggestions(for: "/model cl", commands: withClear) { _, _, _ in
    [SlashCommandChoice(value: "openai/clever"), SlashCommandChoice(value: "anthropic/claude")]
}
check(byModelName.count == 2, "model id after the provider matches as a prefix")
let thinkRow = SessionRow(json(#"{"key":"k","thinkingLevels":[{"id":"low","label":"Low"},{"id":"high","label":"High"}]}"#))!
check(thinkRow.thinkingLevelChoices?.map(\.value) == ["low", "high"], "session thinking levels")

print("Automations")
do {
    let job = CronJob(json(#"""
    {"id":"j1","agentId":"main","name":"Sync calendar","enabled":true,"configRevision":"rev1",
     "schedule":{"kind":"cron","expr":"0 */6 * * *","tz":"America/New_York"},"sessionTarget":"isolated","wakeMode":"now",
     "payload":{"kind":"agentTurn","message":"Sync it.","model":"gpt-5"},
     "delivery":{"mode":"announce","channel":"telegram","to":"@ops"},
     "state":{"nextRunAtMs":1790000000000,"lastRunAtMs":1789990000000,"lastRunStatus":"error","lastError":"invalid_grant","consecutiveErrors":2}}
    """#))!
    check(job.health == .failing && job.consecutiveErrors == 2 && job.lastError == "invalid_grant", "job state from `state`")
    check(job.nextRunAt == Date(timeIntervalSince1970: 1_790_000_000), "next run date")
    check(job.schedule.summary == "0 */6 * * * (America/New_York)" && job.deliveryTarget == "telegram @ops", "schedule and delivery")
    check(job.chatKey(defaultAgentId: "x") == "agent:main:cron:j1", "automation chat key")
    check(CronSchedule(json(#"{"kind":"every","everyMs":900000}"#)).summary == "Every 15 minutes"
          && CronSchedule(json(#"{"kind":"every","everyMs":3600000}"#)).summary == "Every hour", "interval summaries")
    check(!CronSchedule(json(#"{"kind":"on-exit","command":"make"}"#)).isEditable, "event schedules aren't editable")
    let legacy = CronJob(json(#"{"id":"j2","name":"Old","enabled":false,"schedule":{"kind":"every","everyMs":60000},"lastStatus":"ok","nextRunAtMs":1}"#))!
    check(legacy.health == .paused && legacy.lastStatus == .ok && legacy.nextRunAt != nil, "top-level state fields (older gateways)")
    let running = CronJob(json(#"{"id":"j3","name":"R","enabled":true,"schedule":{"kind":"every","everyMs":60000},"state":{"runningAtMs":5}}"#))!
    check(running.health == .running, "running job")

    let run = CronRun(json(#"{"ts":2000,"runAtMs":1000,"jobId":"j1","action":"finished","status":"ok","summary":"Done","sessionKey":"agent:main:cron:j1:run:abc","durationMs":900}"#))!
    check(run.id == "j1@2000" && run.startedAt == Date(timeIntervalSince1970: 1) && run.sessionKey == "agent:main:cron:j1:run:abc",
          "run log entry links to its chat")
    check(CronRun(json(#"{"jobId":"j1"}"#)) == nil, "run entries need a timestamp")

    var draft = CronJobDraft(job: job, defaultAgentId: "main")
    check(draft.scheduleKind == .cron && draft.announce && !draft.hasChanges && draft.patch.isEmpty, "draft from job, unchanged")
    draft.name = "Sync team calendar"
    check(draft.patch.keys.sorted() == ["name"], "patch sends only what changed (keeps delivery target, model)")
    draft.message = "Sync the team calendar."
    check(draft.patch["payload"] == ["kind": "agentTurn", "message": "Sync the team calendar."], "payload patch")
    draft.announce = false
    check(draft.patch["delivery"] == ["mode": "none"], "delivery patch when toggled")
    draft.target = .main
    check(draft.patch["sessionTarget"] == "main" && draft.patch["payload"]?["kind"] == "systemEvent", "main chat → systemEvent")
    draft.cronExpr = "0 7 * *"
    check(draft.problem?.contains("five fields") == true, "cron expression validated")

    var every = CronJobDraft(job: CronJob(json(#"{"id":"e","name":"E","enabled":true,"schedule":{"kind":"every","everyMs":7200000,"anchorMs":5},"payload":{"kind":"agentTurn","message":"m"}}"#))!, defaultAgentId: "main")
    check(every.everyAmount == 2 && every.everyUnit == .hours && every.patch.isEmpty, "interval shown in the largest unit; anchor kept")
    every.everyAmount = 3
    check(every.patch["schedule"] == ["kind": "every", "everyMs": 10_800_000], "schedule patch")

    let script = CronJob(json(#"{"id":"s","name":"S","enabled":true,"schedule":{"kind":"stream","command":["tail"]},"payload":{"kind":"script","script":"x"}}"#))!
    var scriptDraft = CronJobDraft(job: script, defaultAgentId: "main")
    scriptDraft.enabled = false
    check(!scriptDraft.isTaskEditable && !scriptDraft.isScheduleEditable && scriptDraft.problem == nil
          && scriptDraft.patch.keys.sorted() == ["enabled"], "script jobs: only name, agent and enabled are edited")

    var new = CronJobDraft(agentId: "main")
    check(new.problem != nil, "new draft needs a name and task")
    new.name = " Nightly check "
    new.message = "Check backups"
    new.everyAmount = 1
    new.everyUnit = .days
    new.announce = true
    check(new.problem == nil && new.addParams["name"] == "Nightly check" && new.addParams["sessionTarget"] == "isolated"
          && new.addParams["schedule"] == ["kind": "every", "everyMs": 86_400_000]
          && new.addParams["delivery"] == ["mode": "announce", "channel": "last"]
          && new.addParams["payload"] == ["kind": "agentTurn", "message": "Check backups"], "cron.add params")
    new.target = .main
    check(new.addParams["payload"] == ["kind": "systemEvent", "text": "Check backups"] && new.addParams["delivery"] == nil,
          "main-chat job has no delivery")
}

print("Find in chat")
do {
    let findHistory = json("""
    [
     {"role":"user","content":"Where is the Café receipt?","__openclaw":{"id":"f1"}},
     {"role":"assistant","content":[{"type":"thinking","thinking":"Look for the cafe receipt in mail. Receipt, receipt."},
       {"type":"toolCall","id":"t1","name":"exec","arguments":{"command":"grep receipt ~/mail"}}],"__openclaw":{"id":"f2"}},
     {"role":"toolResult","toolCallId":"t1","toolName":"exec","content":[{"type":"text","text":"receipt.pdf\\nRECEIPT-old.pdf"}],"__openclaw":{"id":"f3"}},
     {"role":"assistant","content":[{"type":"text","text":"Found the **receipt**."}],"__openclaw":{"id":"f4"}},
     {"role":"assistant","content":[{"type":"text","text":"Also an older receipt."}],"__openclaw":{"id":"f5"}},
     {"role":"marker","kind":"compaction","__openclaw":{"id":"f6","kind":"compaction"}},
     {"role":"user","content":"thanks","__openclaw":{"id":"f7"}}
    ]
    """)
    let findEntries = TranscriptBuilder.build(findHistory.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) })
    let replies = TranscriptSearch.matches("receipt", in: findEntries)
    check(replies.map(\.entryId) == ["u-f1", "a-f2", "a-f2"], "replies only by default, in transcript order (got \(replies.map(\.entryId)))")
    check(replies.map(\.section) == [.message(0), .message(0), .message(1)], "back-to-back messages are separate sections")
    check(TranscriptSearch.matches("CAFE", in: findEntries).map(\.entryId) == ["u-f1"], "case and diacritics ignored")
    check(TranscriptSearch.matches("  ", in: findEntries).isEmpty && TranscriptSearch.matches("zebra", in: findEntries).isEmpty,
          "blank and missing queries find nothing")
    let everything = TranscriptSearch.matches("receipt", in: findEntries, options: .init(includeThinking: true, includeTools: true))
    check(everything.count == 9, "thinking and tool text searched when included (got \(everything.count))")
    check(everything.filter { $0.section == .thinking }.map(\.occurrence) == [0, 1, 2], "thinking occurrences numbered")
    check(everything.filter { $0.section == .tool("t1") }.map(\.occurrence) == [0, 1, 2],
          "tool input then output counted as one section")
    let order = everything.filter { $0.entryId == "a-f2" }.map(\.section)
    check(order.firstIndex(of: .thinking)! < order.firstIndex(of: .tool("t1"))!
          && order.firstIndex(of: .tool("t1"))! < order.firstIndex(of: .message(0))!,
          "within a turn: thinking, tools, then messages, as drawn")
    check(TranscriptSearch.matches("receipt", in: findEntries, options: .init(includeTools: true, toolTextLimit: 11))
        .filter { $0.section == .tool("t1") }.count == 1, "tool text past the display limit isn't searched")
    check(TranscriptSearch.ranges(of: "aa", in: "aaaa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)],
          "occurrences don't overlap")
    check(TranscriptSearch.ranges(of: "b", in: "🦞b") == [NSRange(location: 2, length: 1)], "ranges are UTF-16, for attributed text")
    check(TranscriptSearch.step(from: nil, count: 3, forward: true) == 0 && TranscriptSearch.step(from: nil, count: 3, forward: false) == 2,
          "first step starts at an end")
    check(TranscriptSearch.step(from: 2, count: 3, forward: true) == 0 && TranscriptSearch.step(from: 0, count: 3, forward: false) == 2,
          "next and previous wrap around")
    check(TranscriptSearch.step(from: 1, count: 0, forward: true) == nil, "no step without matches")
    let rowIndex = Dictionary(findEntries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    check(TranscriptSearch.reselect(nil, in: replies, rowIndex: rowIndex, near: nil) == 2, "a new search selects the latest match")
    check(TranscriptSearch.reselect(replies[1], in: replies, rowIndex: rowIndex, near: 1) == 1, "the selected match survives new messages")
    let refined = TranscriptSearch.matches("older receipt", in: findEntries)
    check(TranscriptSearch.reselect(replies[0], in: refined, rowIndex: rowIndex, near: 0) == 0,
          "a vanished selection falls back near where the reader was")
    check(TranscriptSearch.reselect(nil, in: [], rowIndex: rowIndex, near: nil) == nil, "nothing selected without matches")

    let markdownHistory = json(#"""
    [
     {"role":"assistant","content":[{"type":"text","text":"See [the docs](https://x.example/receipt) for the **hello** world receipt."}],"__openclaw":{"id":"m1"}},
     {"role":"user","content":"and the chart?","__openclaw":{"id":"m1u"}},
     {"role":"assistant","content":[{"type":"text","text":"Here:\n```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\"><text>receipt</text></svg>\n```\n```swift\nlet receipt = 1\n```\n| Item | Note |\n|---|---|\n| receipt | `a|b` |"}],"__openclaw":{"id":"m2"}}
    ]
    """#)
    let markdownEntries = TranscriptBuilder.build(markdownHistory.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) })
    check(TranscriptSearch.renderedTexts(markdown: "See [the docs](https://x.example/receipt) for **hello** world.")
        == ["See the docs for hello world."], "searched text is the rendered text, without Markdown syntax")
    check(TranscriptSearch.matches("receipt", in: [markdownEntries[0]]).count == 1, "link targets aren't counted")
    check(TranscriptSearch.matches("hello world", in: markdownEntries).count == 1, "phrases match across styled words")
    check(TranscriptSearch.renderedTexts(markdown: "1. one\n2. two\n\n> quoted\n\n---\n\nafter")
        == ["1.\tone\n2.\ttwo", "quoted", "after"], "one text per view, with list markers, split at quotes and rules")
    check(TranscriptSearch.renderedTexts(markdown: "| A | B |\n|---|---|\n| 1 |\n") == ["A", "B", "1", ""],
          "tables are searched cell by cell, padded to the header")
    check(TranscriptSearch.renderedTexts(markdown: "line one\nline two") == ["line one\u{2028}line two"],
          "soft line breaks are drawn as line separators")
    let svgMatches = TranscriptSearch.matches("receipt", in: [markdownEntries[2]])
    check(svgMatches.count == 2 && svgMatches.map(\.occurrence) == [0, 1],
          "SVG source (shown as an image) is skipped; code and table cells are counted (got \(svgMatches.count))")
    check(TranscriptSearch.matches("svg", in: [markdownEntries[2]]).isEmpty, "code fence languages aren't searched")
    let renumbered = TranscriptBuilder.build([ChatItem(json(#"{"role":"user","content":"3. first\n4. second","__openclaw":{"id":"n1"}}"#), fallbackIndex: 0)!])
    check(TranscriptSearch.matches("1.", in: renumbered).count == 1 && TranscriptSearch.matches("3.", in: renumbered).isEmpty,
          "list numbers are searched as drawn")
    check(TranscriptSearch.matches("first 2", in: renumbered).isEmpty && TranscriptSearch.matches("rst", in: renumbered).count == 1,
          "quick source check doesn't drop partial words")
}

print("Command palette")
do {
    var history = ChatHistory<String>(limit: 3)
    check(!history.canGoBack && !history.canGoForward && history.current == nil, "history starts empty")
    history.visit("a")
    history.visit("a")
    check(!history.canGoBack && history.current == "a", "revisiting the current chat isn't recorded")
    history.visit("b")
    history.visit("c")
    check(history.backStack == ["a", "b"] && history.recent == ["b", "a"], "visits build the back stack; recent is newest first")
    check(history.goBack() == "b" && history.current == "b" && history.forwardStack == ["c"], "back moves to the previous chat")
    check(history.goBack() == "a" && !history.canGoBack && history.goBack() == nil, "back stops at the first chat")
    check(history.goForward() == "b" && history.goForward() == "c" && !history.canGoForward, "forward retraces")
    _ = history.goBack()
    history.visit("d")
    check(!history.canGoForward && history.backStack == ["a", "b"], "a new visit clears forward")
    history.visit("e")
    history.visit("f")
    check(history.backStack == ["b", "d", "e"], "back stack is capped at the limit")
    check(history.goBack(where: { $0 != "e" && $0 != "d" }) == "b" && history.current == "b" && history.forwardStack == ["f"],
          "back skips chats that no longer exist")
    history.visit("x")
    history.visit("b")
    check(history.recent == ["x"], "recent drops the current chat and duplicates (\(history.recent))")
    history.prune { $0 != "b" }
    check(history.current == nil && history.backStack == ["x"], "prune drops removed chats")

    func item(_ title: String, keywords: [String] = []) -> PaletteItem {
        PaletteItem(id: title, title: title, symbol: "x", keywords: keywords, section: .chats, action: .command(title))
    }
    check(PaletteMatcher.score("", in: "Anything") == 0, "empty query matches")
    check(PaletteMatcher.score("xyz", in: "Japan trip") == nil, "non-matching query rejected")
    check(PaletteMatcher.score("JAPAN", in: "Japan trip") != nil, "case-insensitive")
    check(PaletteMatcher.score("cafe", in: "Café plans") != nil, "diacritic-insensitive")
    check(PaletteMatcher.score("jptr", in: "Japan trip") != nil && PaletteMatcher.score("rtj", in: "Japan trip") == nil,
          "in-order subsequence only")
    check(PaletteMatcher.score("trip", in: "Japan trip")! > PaletteMatcher.score("jptr", in: "Japan trip")!, "substring beats subsequence")
    check(PaletteMatcher.score("jap", in: "Japan trip")! > PaletteMatcher.score("rip", in: "Japan trip")!, "prefix beats mid-word")
    let items = [item("Paper digest"), item("Japan trip"), item("home-lab", keywords: ["Discord"]), item("New Chat with Scout")]
    check(PaletteMatcher.rank(items, query: "").map(\.title) == items.map(\.title), "empty query keeps order")
    check(PaletteMatcher.rank(items, query: "trip").map(\.title) == ["Japan trip"], "filters by title")
    check(PaletteMatcher.rank(items, query: "discord").map(\.title) == ["home-lab"], "matches keywords")
    check(PaletteMatcher.rank(items, query: "new scout").map(\.title) == ["New Chat with Scout"], "every word must match")
    check(PaletteMatcher.rank(items, query: "p").first?.title == "Paper digest", "best match first")
    check(PaletteMatcher.rank([item("Scratch pad"), item("Pad")], query: "pad").map(\.title) == ["Pad", "Scratch pad"],
          "exact title outranks a later match")
}

print("Composer drafts")
await checkDrafts()

@MainActor
func checkDrafts() async {
    let profile = GatewayProfile(name: "Drafts", url: "ws://127.0.0.1:1", authMode: .none)
    let gatewayFolder = draftsRoot.appending(path: profile.id.uuidString)
    func folders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: gatewayFolder.path(percentEncoded: false))) ?? []
    }
    let photo = OutgoingAttachment(fileName: "photo.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    let notes = OutgoingAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("hello".utf8))

    let first = GatewayStore(profile: profile)
    let alpha = first.chat(for: "agent:main:alpha")
    let beta = first.chat(for: "agent:main:beta")
    await alpha.load()
    await beta.load()
    check(alpha.draft.isEmpty && beta.draft.isEmpty, "new chats start with an empty draft")
    alpha.draft.text = "half-written thought"
    alpha.draft.attachments = [photo, notes]
    beta.draft.text = "/model"
    check(first.chat(for: "agent:main:alpha").draft.text == "half-written thought"
          && first.chat(for: "agent:main:alpha").draft.attachments.map(\.id) == [photo.id, notes.id],
          "switching chats keeps each chat's draft")
    check(first.chat(for: "agent:main:beta").draft.text == "/model", "drafts are per chat")

    let saved = await waitFor("debounced draft save", timeout: 5) { folders().count == 2 }
    check(saved, "drafts are saved without an explicit flush")

    // Relaunch: a fresh store for the same Gateway.
    let second = GatewayStore(profile: profile)
    let alphaAgain = second.chat(for: "agent:main:alpha")
    await alphaAgain.load()
    check(alphaAgain.draft.text == "half-written thought", "draft text survives relaunch")
    check(alphaAgain.draft.attachments == [photo, notes], "pending attachments survive relaunch (bytes, names, ids)")
    let betaAgain = second.chat(for: "agent:main:beta")
    await betaAgain.load()
    check(betaAgain.draft.text == "/model" && betaAgain.draft.attachments.isEmpty, "other chat's draft restored separately")

    alphaAgain.draft.attachments.removeAll { $0.id == photo.id }
    await alphaAgain.flushDraft()
    let alphaFolder = gatewayFolder.appending(path: folders().first { name in
        let files = (try? FileManager.default.contentsOfDirectory(atPath: gatewayFolder.appending(path: name).path(percentEncoded: false))) ?? []
        return files.contains("\(notes.id.uuidString).bin")
    } ?? "missing")
    let alphaFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: alphaFolder.path(percentEncoded: false))) ?? [])
    check(alphaFiles == ["draft.json", "\(notes.id.uuidString).bin"], "removed attachment's file is deleted (\(alphaFiles.sorted()))")

    // Sending clears the composer.
    alphaAgain.draft = ComposerDraft()
    await alphaAgain.flushDraft()
    check(folders().count == 1, "an empty draft removes its folder")
    let third = GatewayStore(profile: profile)
    let alphaThird = third.chat(for: "agent:main:alpha")
    await alphaThird.load()
    check(alphaThird.draft.isEmpty, "a sent draft doesn't come back after relaunch")

    // Typing before the saved draft is read wins over the saved one.
    let fourth = GatewayStore(profile: profile)
    let betaFourth = fourth.chat(for: "agent:main:beta")
    betaFourth.draft.text = "typed first"
    await betaFourth.load()
    check(betaFourth.draft.text == "typed first", "a draft started before restore isn't overwritten")
    await betaFourth.flushDraft()
    let fifth = GatewayStore(profile: profile)
    let betaFifth = fifth.chat(for: "agent:main:beta")
    await betaFifth.load()
    check(betaFifth.draft.text == "typed first", "latest draft is the one on disk")

    // Rapid edits flushed at once still land in order.
    for index in 1...20 { betaFifth.draft.text = "edit \(index)" }
    await betaFifth.flushDraft()
    let sixth = GatewayStore(profile: profile)
    let betaSixth = sixth.chat(for: "agent:main:beta")
    await betaSixth.load()
    check(betaSixth.draft.text == "edit 20", "last of many quick edits is saved (got \(betaSixth.draft.text))")
    betaSixth.draft = ComposerDraft()
    await betaSixth.flushDraft()
    check(folders().isEmpty, "all drafts cleared")
}

print("Context usage")
do {
    let fresh = SessionRow(json(#"{"key":"k","totalTokens":172000,"totalTokensFresh":true,"inputTokens":1200,"outputTokens":340,"contextTokens":200000}"#))!
    let usage = ContextUsage(row: fresh)
    check(usage == ContextUsage(used: 172_000, limit: 200_000) && usage?.level == .warning && usage?.percent == 86,
          "usage from row (\(String(describing: usage)))")
    check(usage?.summary == "172k / 200k" && usage?.percentLabel == "86%" && usage?.remaining == 28_000, "usage labels")
    check(fresh.inputTokens == 1200 && fresh.outputTokens == 340, "last run in/out tokens")
    let stale = SessionRow(json(#"{"key":"k","totalTokens":198000,"totalTokensFresh":false,"contextTokens":200000}"#))!
    check(ContextUsage(row: stale)?.level == .normal && ContextUsage(row: stale)?.summary == "~198k / 200k",
          "stale totals are approximate and never warn")
    let budget = SessionRow(json(#"{"key":"k","totalTokens":150000,"contextTokens":200000,"contextBudgetStatus":{"promptBudgetBeforeReserve":160000}}"#))!
    let budgetUsage = ContextUsage(row: budget)
    check(budgetUsage?.limit == 160_000 && budgetUsage?.isPromptBudget == true && budgetUsage?.level == .warning,
          "prompt budget preferred over the window")
    let noLimit = SessionRow(json(#"{"key":"k","totalTokens":12000,"contextTokens":0}"#))!
    check(ContextUsage(row: noLimit) == nil && ContextUsage(row: noLimit, fallbackLimit: 128_000)?.limit == 128_000,
          "fallback limit when the row has none")
    check(ContextUsage(row: SessionRow(json(#"{"key":"k","contextTokens":200000}"#))!) == nil && ContextUsage(row: nil) == nil,
          "no snapshot, no meter")
    check(ContextUsage(used: 169_999, limit: 200_000).level == .normal && ContextUsage(used: 170_000, limit: 200_000).level == .warning
          && ContextUsage(used: 190_000, limit: 200_000).level == .critical, "warning at 85%, critical at 95%")
    check(ContextUsage(used: 260_000, limit: 200_000).percent == 100 && ContextUsage(used: 260_000, limit: 200_000).remaining == 0,
          "overflow clamps")
    check([950, 12_300, 40_000, 99_960, 172_400, 999_700, 1_260_000].map(TokenCount.format)
          == ["950", "12.3k", "40k", "100k", "172k", "1M", "1.3M"], "token formatting")
    check(ModelChoice(json(#"{"id":"a","provider":"p","contextWindow":1000000,"contextTokens":200000}"#))?.contextTokens == 200_000
          && ModelChoice(json(#"{"id":"a","provider":"p","contextWindow":1000000}"#))?.contextTokens == 1_000_000
          && ModelChoice(json(#"{"id":"a","provider":"p"}"#))?.contextTokens == nil, "model context cap prefers contextTokens")
    check(CompactionState.finished(before: 172_000, after: 31_000).message == "Compacted 172k → 31k tokens."
          && CompactionState.finished(before: nil, after: 31_000).message == "Compacted to 31k tokens."
          && CompactionState.running(before: 1).isRunning && !CompactionState.skipped("x").isRunning, "compaction messages")
}

// MARK: Live

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--live"), arguments.count > index + 2 {
    let url = arguments[index + 1]
    let token = arguments[index + 2]
    print("Live against \(url)")
    await runLive(url: url, token: token)
}
if arguments.contains("--demo") {
    print("Built-in demo")
    await runDemo()
    print("Chat navigation")
    await runNavigation()
}

print("\n\(passes) passed, \(failures) failed")
try? FileManager.default.removeItem(at: draftsRoot)
exit(failures == 0 ? 0 : 1)

@MainActor
func waitFor(_ label: String, timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    print("    … timed out waiting for \(label)")
    return condition()
}

@MainActor
func runDemo() async {
    let profile = GatewayProfile.demo()
    check(profile.isDemo && profile.authMode == .none, "demo profile")
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo connection") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo connected and bootstrapped")
    guard connected else { return }
    check(gateway.agents.count >= 3, "agents (\(gateway.agents.map(\.name)))")
    check(gateway.sessions.count >= 5, "sessions (\(gateway.sessions.count))")

    let key = "agent:main:main"
    await gateway.loadCommands(sessionKey: key, agentId: "main")
    let demoCommands = gateway.slashCommands(for: key)
    check(demoCommands.contains { $0.name == "restart" } && demoCommands.contains { $0.source == "skill" },
          "demo commands.list (\(demoCommands.count))")
    gateway.selectedKey = key
    let chat = gateway.chat(for: key)
    let loaded = await waitFor("history") { chat.hasLoaded }
    check(loaded && !chat.entries.isEmpty, "welcome history loaded")

    let trip = gateway.chat(for: "agent:main:dashboard:trip")
    await trip.load()
    check(trip.hasMoreHistory && trip.items.count == 120, "trip latest page (\(trip.items.count))")
    await trip.loadOlder()
    await trip.loadOlder()
    check(!trip.hasMoreHistory && trip.items.count == 302, "trip paged to start (\(trip.items.count))")

    let before = chat.entries.count
    await chat.send("show me a tool and an image")
    var sawThinking = false
    var sawTool = false
    let finished = await waitFor("demo reply", timeout: 20) {
        if case let .assistant(turn)? = chat.entries.last, turn.isStreaming {
            if !turn.thinking.isEmpty { sawThinking = true }
            if !turn.tools.isEmpty { sawTool = true }
        }
        return !chat.isRunning && chat.entries.count > before
    }
    check(finished, "demo reply finished")
    check(sawThinking && sawTool, "demo streamed thinking and a tool")
    if case let .assistant(turn)? = chat.entries.last, let image = turn.images.first {
        check(!turn.body.isEmpty, "demo reply has text")
        gateway.images.load(image, sessionKey: key)
        let decoded = await waitFor("chart") { gateway.images.cached(image) != nil }
        check(decoded, "demo chart decoded")
    } else {
        check(false, "demo reply carries a chart")
    }

    await gateway.loadModels(agentId: "main")
    check(!(gateway.modelCatalogs["main"] ?? []).isEmpty, "demo model catalog")
    await gateway.setModel(key, to: "openai/gpt-5.6-sol")
    let switched = await waitFor("model switch") { gateway.sessions[key]?.modelRef == "openai/gpt-5.6-sol" }
    check(switched, "demo model switch")

    await gateway.automations.load()
    check(gateway.automations.hasLoaded && !gateway.automations.supported && gateway.automations.jobs.isEmpty,
          "gateway without cron.* shows automations unavailable")

    await chat.send("please approve this")
    let approvalSeen = await waitFor("approval") { !gateway.approvals.isEmpty }
    check(approvalSeen, "demo approval surfaced")
    if let approval = gateway.approvals.first {
        await gateway.resolveApproval(approval, decision: "allow-once")
        check(gateway.approvals.isEmpty, "demo approval resolved")
    }

    let settled = await waitFor("approval run to finish", timeout: 20) { !chat.isRunning }
    check(settled, "demo approval run finished")
    await chat.send("follow a plan")
    let demoPlanned = await waitFor("demo progress card", timeout: 20) {
        chat.progressCard?.isComplete == true && !chat.isRunning
    }
    check(demoPlanned, "demo progress card walks its plan")

    let demoUsage = gateway.contextUsage(for: key)
    check(demoUsage != nil && demoUsage!.used >= 172_000 && demoUsage!.limit == 200_000, "demo context meter (\(demoUsage?.summary ?? "none"))")
    check(!gateway.canCompactDirectly, "demo compacts through /compact")
    await chat.compact()
    let demoCompacted = await waitFor("demo compaction", timeout: 20) {
        if case .finished = chat.compaction { return !chat.isRunning }
        return false
    }
    if case let .finished(before?, after?) = chat.compaction {
        check(demoCompacted && after < before && gateway.contextUsage(for: key)?.used == after,
              "demo compaction \(chat.compaction?.message ?? "")")
    } else {
        check(false, "demo compaction finished (\(String(describing: chat.compaction)))")
    }

    let newKey = await gateway.createSession(agentId: "research", label: "Demo check", category: "Work")
    check(newKey != nil && gateway.sessions[newKey ?? ""] != nil, "demo sessions.create")

    // Command palette over the demo's chats.
    check(gateway.pinnedChats.map(\.key) == ["agent:main:discord:channel:123"], "pinned chats (\(gateway.pinnedChats.map(\.key)))")
    let tripKey = "agent:main:dashboard:trip"
    await gateway.patch(tripKey, ["pinned": true])
    let pinnedTrip = await waitFor("pin") { gateway.pinnedChats.count == 2 }
    let sidebarOrder = gateway.sections().flatMap { $0.channels.map(\.row.key) }.filter { $0 == tripKey || $0.contains("discord") }
    check(pinnedTrip && gateway.pinnedChats.map(\.key) == sidebarOrder, "⌘1–⌘9 follow the sidebar's order")
    let recentTarget = Notifier.Target(gatewayId: gateway.id, sessionKey: "agent:research:dashboard:papers")
    let chatItems = CommandPalette.chatItems(gateways: [gateway], selectedGatewayId: gateway.id, recent: [recentTarget])
    check(chatItems.first?.action == .openChat(recentTarget), "recent chats listed first")
    check(!chatItems.contains { $0.id.contains(":subagent:") }, "subagent runs left out")
    check(Set(chatItems.map(\.id)).count == chatItems.count, "each chat listed once")
    check(chatItems.first { $0.id.hasSuffix(gateway.pinnedChats[0].key) }?.shortcut == "⌘1"
          && chatItems.first { $0.id.hasSuffix(gateway.pinnedChats[1].key) }?.shortcut == "⌘2", "pinned chats show their shortcut")
    check(PaletteMatcher.rank(chatItems, query: "scout digest").first?.title == "Paper digest", "chats match on agent name")
    let newChats = CommandPalette.newChatItems(gateway: gateway)
    check(newChats.count == gateway.agents.count && newChats.contains { $0.action == .newChat(gatewayId: gateway.id, agentId: "research") },
          "a New Chat item per agent")
    check(CommandPalette.gatewayItems(gateways: [gateway], selectedGatewayId: gateway.id).isEmpty, "no gateway switching with one gateway")
    if let mainRow = gateway.sessions[key] {
        let models = CommandPalette.modelItems(gateway: gateway, row: mainRow)
        check(models.first?.action == .setModel(nil) && models.count == (gateway.modelCatalogs["main"]?.count ?? 0) + 1,
              "models page lists default plus the catalog")
        check(models.first { $0.action == .setModel("openai/gpt-5.6-sol") }?.subtitle?.hasSuffix("Current") == true,
              "models page marks the session's model")
    }
    await gateway.patch(tripKey, ["pinned": false])
    gateway.stop()
}

/// Back/forward and ⌘1–⌘9 through `AppModel`, across two demo Gateways.
@MainActor
func runNavigation() async {
    let app = AppModel()
    guard app.gateways.isEmpty else {
        check(false, "navigation checks need an empty profile list (found \(app.gateways.count))")
        return
    }
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removeObject(forKey: "pincer.selectedGateway")
    }
    let first = app.add(.demo(), secret: nil)
    let ready = await waitFor("demo connection") { first.state.isConnected && !first.sessions.isEmpty }
    check(ready, "navigation demo connected")
    guard ready else { return }
    func target(_ gateway: GatewayStore, _ key: String) -> Notifier.Target { Notifier.Target(gatewayId: gateway.id, sessionKey: key) }
    let main = target(first, "agent:main:main")
    let trip = target(first, "agent:main:dashboard:trip")
    let papers = target(first, "agent:research:dashboard:papers")

    app.open(main)
    app.open(trip)
    app.open(papers)
    check(app.history.current == papers && app.canGoBack && !app.canGoForward, "opening chats records history")
    app.goBack()
    check(first.selectedKey == trip.sessionKey && app.history.current == trip && app.canGoForward, "Back opens the previous chat")
    // What RootView does after the selection changes; it must not disturb the history.
    app.updateVisible()
    app.goBack()
    check(first.selectedKey == main.sessionKey && !app.canGoBack, "Back again reaches the first chat")
    app.goForward()
    check(first.selectedKey == trip.sessionKey && app.history.forwardStack == [papers], "Forward retraces")
    first.selectedKey = main.sessionKey
    app.updateVisible()
    check(!app.canGoForward && app.history.current == main, "picking a chat in the sidebar clears Forward")

    app.openPinned(1)
    check(first.selectedKey == first.pinnedChats.first?.key, "⌘1 opens the first pinned chat")
    let beforeMissing = app.history.current
    app.openPinned(9)
    app.openPinned(0)
    check(app.history.current == beforeMissing, "⌘ with no pinned chat at that number does nothing")

    let second = app.add(.demo(), secret: nil)
    let secondReady = await waitFor("second demo") { second.state.isConnected && !second.sessions.isEmpty }
    check(secondReady && app.selectedGatewayId == second.id, "second gateway added and selected")
    let secondTrip = target(second, "agent:main:dashboard:trip")
    app.open(secondTrip)
    let beforeSwitch = app.history.current
    app.open(papers)
    check(app.selectedGatewayId == first.id && app.history.backStack.last == beforeSwitch,
          "switching gateways records only the opened chat")
    app.goBack()
    check(app.selectedGatewayId == second.id && second.selectedKey == secondTrip.sessionKey, "Back crosses gateways")
    app.remove(second.id)
    check(!app.history.backStack.contains { $0.gatewayId == second.id } && app.history.current?.gatewayId != second.id,
          "removing a gateway drops its chats from history")
    app.goBack()
    check(app.selectedGatewayId == first.id, "Back still works after removing a gateway")
}

@MainActor
func runLive(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    // What launch does: the scene turning active asks for a reconnect mid-handshake.
    try? await Task.sleep(for: .milliseconds(Int(ProcessInfo.processInfo.environment["RACE_MS"] ?? "30") ?? 30))
    gateway.reconnectIfNeeded()

    var sawPairing = false
    var sawReconnecting = false
    let connected = await waitFor("connection", timeout: 25) {
        if case .awaitingPairing = gateway.state { sawPairing = true }
        if case .reconnecting = gateway.state { sawReconnecting = true }
        return gateway.state.isConnected && !gateway.sessions.isEmpty
    }
    check(connected, "connected and bootstrapped (pairing seen: \(sawPairing))")
    check(!sawReconnecting, "first connect never reports reconnecting")
    guard connected else { return }
    check(gateway.agents.count >= 3, "agents.list (\(gateway.agents.map(\.name)))")
    check(gateway.sessions.count >= 5, "sessions.subscribe (\(gateway.sessions.count) rows)")
    let sections = gateway.sections()
    check(sections.contains { $0.channels.contains { !$0.threads.isEmpty } }, "subagent session nested as thread")
    gateway.organization = .group
    check(gateway.sections().contains { $0.title == "Home" }, "group organization")
    gateway.organization = .agent

    let key = "agent:main:main"
    await gateway.loadCommands(sessionKey: key, agentId: "main")
    let liveCommands = gateway.slashCommands(for: key)
    check(liveCommands.contains { $0.name == "weather" && $0.source == "plugin" } && !liveCommands.contains { $0.name == "pair" },
          "commands.list (\(liveCommands.map(\.name)))")
    check(liveCommands.first { $0.name == "verbose" }?.args.first?.choices.count == 3, "commands.list includes args")
    gateway.selectedKey = key
    let chat = gateway.chat(for: key)
    let loaded = await waitFor("history") { chat.hasLoaded }
    check(loaded, "chat.history loaded")
    let turns = chat.entries.compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry { return turn }
        return nil
    }
    check(turns.contains { !$0.thinking.isEmpty }, "history includes thinking")
    check(turns.contains { !$0.tools.isEmpty && $0.tools.allSatisfy { $0.result != nil } }, "history includes paired tool results")
    if let image = turns.flatMap(\.images).first {
        gateway.images.load(image, sessionKey: key)
        let decoded = await waitFor("artifact") { gateway.images.cached(image) != nil }
        check(decoded, "artifacts.download → decoded image")
    } else {
        check(false, "history includes an image")
    }

    let trip = gateway.chat(for: "agent:main:dashboard:trip")
    await trip.load()
    let firstPage = trip.items.map(\.id)
    check(trip.hasMoreHistory && firstPage.count == 120, "latest page only (\(firstPage.count))")
    await trip.loadOlder()
    check(trip.items.count == 240 && Array(trip.items.suffix(120).map(\.id)) == firstPage,
          "older page prepended; newer rows keep their ids (\(trip.items.count))")
    await trip.load(force: true)
    check(trip.items.count >= 240, "tail reload keeps paged history (\(trip.items.count))")
    await trip.loadOlder()
    check(!trip.hasMoreHistory && trip.items.count == 302, "reaches the start (\(trip.items.count))")
    check(trip.items.first?.plainText == "Idea for day 1?", "oldest message first")

    let research = gateway.chat(for: "agent:research:main")
    await research.load()
    let recovered = await waitFor("full message") {
        research.items.contains { !$0.isCapped && $0.plainText.hasSuffix("END OF REPORT") }
    }
    check(recovered && !research.items.contains { $0.plainText.contains("...(truncated)...") },
          "capped message replaced via chat.message.get")
    await research.load(force: true)
    check(research.items.contains { $0.plainText.hasSuffix("END OF REPORT") }, "full copy survives a history reload")

    let before = chat.entries.count
    let sendNonce = UUID().uuidString.prefix(8)
    await chat.send("show me a tool and an image please \(sendNonce)")
    var sawLive = false
    var sawLiveTool = false
    var sawLiveThinking = false
    let finished = await waitFor("run to finish", timeout: 20) {
        if case let .assistant(turn)? = chat.entries.last, turn.isStreaming {
            sawLive = true
            if !turn.tools.isEmpty { sawLiveTool = true }
            if !turn.thinking.isEmpty { sawLiveThinking = true }
        }
        return sawLive && !chat.isRunning && chat.entries.count > before
    }
    check(finished, "chat.send streamed and finished")
    check(sawLiveThinking, "live thinking streamed")
    check(sawLiveTool, "live tool activity streamed")
    if case let .assistant(turn)? = chat.entries.last {
        check(!turn.isStreaming && !turn.body.isEmpty, "final reply committed from history")
        check(!turn.images.isEmpty, "final reply carries an image")
    } else {
        check(false, "last entry is the assistant reply")
    }
    let userTurns = chat.entries.filter { if case let .user(item) = $0 { item.plainText.contains("please \(sendNonce)") } else { false } }
    check(userTurns.count == 1, "optimistic send merged, not duplicated (\(userTurns.count))")

    await chat.send("follow a plan \(sendNonce)")
    var sawProgress = false
    let planned = await waitFor("progress card to complete", timeout: 20) {
        if chat.progressCard?.currentStep?.status == .inProgress { sawProgress = true }
        return chat.progressCard?.isComplete == true && !chat.isRunning
    }
    check(sawProgress && planned, "progressCard.changed → live progress card")
    check(chat.progressCard?.steps.count == 3 && chat.progressCard?.markdown != nil, "card has steps and note")
    await chat.dismissProgressCard()
    check(chat.progressCard == nil, "progressCard.put dismisses a finished card")
    await chat.load(force: true)
    let stayedDismissed = await waitFor("card read after reload", timeout: 2) { chat.progressCard != nil }
    check(!stayedDismissed, "dismissed card stays gone after reload")

    await gateway.patch(key, ["pinned": true])
    let pinned = await waitFor("pin") { gateway.sessions[key]?.isPinned == true }
    check(pinned, "sessions.patch round-trips via sessions.changed")

    // Model picker: the catalog loads, a new model applies to new replies, older ones keep theirs.
    await gateway.loadModels(agentId: "main")
    check(gateway.modelCatalogs["main"]?.contains { $0.ref == "openai/gpt-5.6-sol" } == true, "models.list catalog")
    check(gateway.defaultModelRef == "anthropic/claude-opus-4-8", "default model from sessions.list")
    func lastTurn() -> AssistantTurn? {
        for entry in chat.entries.reversed() {
            if case let .assistant(turn) = entry { return turn }
        }
        return nil
    }
    let previousModel = lastTurn()?.modelRef
    check(previousModel == "anthropic/claude-opus-4-8", "reply attributed to the model that wrote it (\(previousModel ?? "nil"))")
    let previousTurnId = lastTurn()?.id
    await gateway.setModel(key, to: "openai/gpt-5.6-sol")
    let switched = await waitFor("model switch") { gateway.sessions[key]?.modelRef == "openai/gpt-5.6-sol" }
    check(switched && gateway.sessions[key]?.modelOverrideSource == "user", "sessions.patch model round-trips")
    let beforeSwitchSend = chat.entries.count
    await chat.send("which model now?")
    let switchedReply = await waitFor("reply after switch", timeout: 20) {
        !chat.isRunning && chat.entries.count > beforeSwitchSend && lastTurn()?.isStreaming == false
    }
    check(switchedReply && lastTurn()?.modelRef == "openai/gpt-5.6-sol", "new reply uses the selected model")
    let oldTurn = chat.entries.lazy.compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry, turn.id == previousTurnId { return turn }
        return nil
    }.first
    check(oldTurn?.modelRef == "anthropic/claude-opus-4-8", "earlier reply keeps its original model")
    await gateway.setModel(key, to: nil)
    let reset = await waitFor("model reset") {
        gateway.sessions[key]?.modelOverrideSource == nil && gateway.sessions[key]?.modelRef == "anthropic/claude-opus-4-8"
    }
    check(reset, "model reset to default")

    await chat.send("please approve this")
    let approvalSeen = await waitFor("approval") { !gateway.approvals.isEmpty }
    check(approvalSeen, "exec approval surfaced")
    if let approval = gateway.approvals.first {
        await gateway.resolveApproval(approval, decision: "deny")
        check(gateway.approvals.isEmpty, "approval resolved")
    }

    let newKey = await gateway.createSession(agentId: "research", label: "Pincer check", category: "Work")
    check(newKey != nil && gateway.sessions[newKey ?? ""] != nil, "sessions.create")

    // Drag and drop between groups.
    if let newKey {
        let savedOrganization = gateway.organization
        gateway.organization = .group
        func section(_ id: String) -> SidebarSection? { gateway.sections().first { $0.id == id } }
        if let work = section("group:Work") {
            check(gateway.groupDropValue(for: newKey, onto: work) == nil, "drop onto its own group is ignored")
        }
        let home = SidebarSection(id: "group:Home", title: "Home", emoji: nil, channels: [], kind: .group("Home"))
        let didMove = await gateway.moveToGroup(newKey, droppedOn: home)
        check(didMove, "drop onto another group moves the chat")
        let moved = await waitFor("drop move") { gateway.sessions[newKey]?.category == "Home" }
        check(moved && section("group:Home")?.channels.contains { $0.id == newKey } == true, "dropped chat shows in its new group")
        let ungrouped = SidebarSection(id: "group:", title: "Ungrouped", emoji: nil, channels: [], kind: .other)
        let didUngroup = await gateway.moveToGroup(newKey, droppedOn: ungrouped)
        check(didUngroup, "drop onto Ungrouped")
        let removed = await waitFor("drop ungroup") { gateway.sessions[newKey]?.category == nil }
        check(removed, "drop onto Ungrouped removes the group")
        check(gateway.groupDropValue(for: newKey, onto: ungrouped) == nil, "ungrouped chat ignores Ungrouped drop")
        let recent = SidebarSection(id: "recent", title: "Recent", emoji: nil, channels: [], kind: .other)
        check(gateway.groupDropValue(for: newKey, onto: recent) == nil, "drop onto Recent is ignored")
        check(gateway.groupDropValue(for: "agent:nope:missing", onto: home) == nil, "unknown dropped key is ignored")
        // Like Discord: a grouped chat dropped on its home agent section leaves its group.
        gateway.organization = .servers
        await gateway.patch(newKey, ["category": "Work"])
        _ = await waitFor("regroup") { gateway.sessions[newKey]?.category == "Work" }
        let agentHome = SidebarSection(id: "agent:research", title: "Research", emoji: nil, channels: [], kind: .agent("research"))
        let otherAgent = SidebarSection(id: "agent:main", title: "Main", emoji: nil, channels: [], kind: .agent("main"))
        check(gateway.groupDropValue(for: newKey, onto: agentHome) == .null, "drop onto home agent section ungroups")
        check(gateway.groupDropValue(for: newKey, onto: otherAgent) == nil, "drop onto another agent is ignored")
        gateway.organization = savedOrganization
    }

    // A second device: names set on it before syncing are uploaded, and renames flow both ways.
    let otherProfile = GatewayProfile(name: "Mock 2", url: url, authMode: .token)
    otherProfile.secret = token
    let other = GatewayStore(profile: otherProfile)
    let early = ChatServer(provider: "discord", id: "server-early", name: nil)
    let renamed = ChatServer(provider: "discord", id: "server-renamed", name: nil)
    other.renameServer(early, to: "Set Before Sync")
    other.start()
    let otherConnected = await waitFor("second device") { other.state.isConnected && !other.sessions.isEmpty }
    check(otherConnected, "second device connected")
    let uploaded = await waitFor("first-sync upload") {
        gateway.displayName(for: early) == "Set Before Sync"
    }
    check(uploaded, "names set before syncing reach other devices")
    gateway.renameServer(renamed, to: "Synced Name")
    let synced = await waitFor("rename sync") { other.displayName(for: renamed) == "Synced Name" }
    check(synced, "server rename syncs through users.prefs")
    other.renameServer(renamed, to: nil)
    let cleared = await waitFor("rename clear") { gateway.displayName(for: renamed) != "Synced Name" }
    check(cleared, "clearing a server name syncs")
    // Chat icons sync the same way, through the `pincer.chatIcons` pref.
    if let iconKey = gateway.sessions.keys.sorted().first {
        gateway.setIcon("star.fill", for: iconKey)
        let iconSynced = await waitFor("icon sync") { other.customIcon(for: iconKey) == "star.fill" }
        check(iconSynced, "chat icon syncs through users.prefs")
        other.setIcon(nil, for: iconKey)
        let iconCleared = await waitFor("icon clear") { gateway.customIcon(for: iconKey) == nil }
        check(iconCleared, "clearing a chat icon syncs")
    }

    // Groups: created empty, kept when emptied, reordered, and chats arranged by hand.
    do {
        let savedOrganization = gateway.organization
        gateway.organization = .group
        other.organization = .group
        func groupSection(_ store: GatewayStore, _ name: String) -> SidebarSection? {
            store.sections().first { $0.kind == .group(name) }
        }
        let created = await gateway.createGroup("Empty")
        check(created && groupSection(gateway, "Empty")?.channels.isEmpty == true, "empty group created")
        let duplicate = await gateway.createGroup("Empty")
        check(!duplicate, "duplicate group name rejected")
        let seen = await waitFor("empty group on other device") { other.groupNames.contains("Empty") }
        check(seen && groupSection(other, "Empty") != nil, "empty group shows on other devices")
        check(gateway.sections(search: "zzz-no-match").allSatisfy { $0.kind != .group("Empty") }, "empty group hidden while searching")

        await gateway.moveGroup("Empty", before: gateway.groupNames.first)
        check(gateway.groupNames.first == "Empty", "group moved to the top (\(gateway.groupNames))")
        let reordered = await waitFor("group order sync") { other.groupNames.first == "Empty" }
        check(reordered, "group order syncs")
        await gateway.moveGroup("Empty", before: nil)
        check(gateway.groupNames.last == "Empty", "group moved to the end (\(gateway.groupNames))")

        let personal = gateway.groupOrder("Personal")
        if let only = personal.first {
            await gateway.moveChat(only, toGroup: "Empty", before: nil)
            let moved = await waitFor("chat into Empty") { gateway.sessions[only]?.category == "Empty" }
            check(moved, "chat moved into a new group")
            let emptied = await waitFor("Personal emptied") { gateway.groupOrder("Personal").isEmpty }
            check(emptied && groupSection(gateway, "Personal") != nil && gateway.groupNames.contains("Personal"),
                  "group stays after its last chat leaves")
            await gateway.moveChat(only, toGroup: "Personal", before: nil)
            _ = await waitFor("chat back") { gateway.sessions[only]?.category == "Personal" }
        }

        // Arrange chats within a group by hand.
        let workKeys = gateway.sessions.values.filter { !$0.isSubagent && !$0.isArchived }.map(\.key).sorted().prefix(3)
        for key in workKeys where gateway.sessions[key]?.category != "Work" {
            await gateway.moveChat(key, toGroup: "Work", before: nil)
        }
        let filled = await waitFor("work filled") { workKeys.allSatisfy { gateway.sessions[$0]?.category == "Work" } }
        check(filled, "chats moved into a group")
        let work = gateway.groupOrder("Work")
        if work.count >= 2, let last = work.last {
            await gateway.moveChat(last, toGroup: "Work", before: work.first)
            check(gateway.groupOrder("Work").first == last, "chat moved to the top of its group")
            check(groupSection(gateway, "Work")?.channels.first?.id == last, "sidebar shows the new chat order")
            let orderSynced = await waitFor("chat order sync") { other.groupOrder("Work").first == last }
            check(orderSynced, "chat order syncs through users.prefs")
            await gateway.moveChat(last, toGroup: "Work", before: nil)
            check(gateway.groupOrder("Work").last == last, "chat moved to the end of its group")
        }

        gateway.setGroupIcon("star.fill", for: "Empty")
        let iconSynced = await waitFor("group icon sync") { other.groupIcon(for: "Empty") == "star.fill" }
        check(iconSynced, "group icon syncs through users.prefs")
        await gateway.renameGroup("Empty", to: "Renamed")
        let renamed = await waitFor("rename group") { gateway.groupNames.contains("Renamed") && !gateway.groupNames.contains("Empty") }
        check(renamed, "empty group renamed")
        check(gateway.groupIcon(for: "Renamed") == "star.fill" && gateway.groupIcon(for: "Empty") == nil, "group icon follows a rename")
        let members = gateway.groupOrder("Work")
        await gateway.deleteGroup("Work")
        let deleted = await waitFor("delete group") {
            !gateway.groupNames.contains("Work") && members.allSatisfy { gateway.sessions[$0]?.category == nil }
        }
        check(deleted && members.allSatisfy { gateway.sessions[$0] != nil }, "deleting a group ungroups its chats")
        let deletedOther = await waitFor("delete sync") { !other.groupNames.contains("Work") }
        check(deletedOther, "group deletion syncs")
        await gateway.deleteGroup("Renamed")
        check(gateway.groupIcon(for: "Renamed") == nil, "deleting a group clears its icon")
        gateway.organization = savedOrganization
    }
    other.stop()

    // Automations: read-only without admin, then run, pause, edit, create and delete.
    let automations = gateway.automations
    await automations.load()
    check(automations.supported && automations.jobs.count == 3 && automations.scheduler?.enabled == true,
          "cron.list + cron.status (\(automations.jobs.map(\.id)))")
    check(automations.jobs.last?.id == "paper-digest" && automations.jobs.last?.health == .paused, "paused jobs listed last")
    await automations.loadRuns(for: "disk-check")
    check(automations.runs["disk-check"]?.first?.status == .error
          && automations.runs["disk-check"]?.first?.sessionKey == "agent:main:cron:disk-check", "cron.runs history with chat link")
    check(!automations.canEdit, "automation writes need admin")
    if let disk = automations.job("disk-check") {
        let denied = await automations.runNow(disk)
        check(!denied && automations.operation(for: "disk-check").error?.contains("Full Management") == true, "run denied without admin")
    }
    // Gateway settings: read-only without admin, then edits through config.patch and plugins.*.
    let settings = gateway.settings
    await settings.load()
    check(settings.hasLoaded && settings.snapshot?.isValid == true && settings.schema != nil, "config.get + config.schema loaded")
    check(settings.value(at: ["gateway", "auth", "token"])?.isRedacted == true, "secrets arrive redacted")
    let weatherKeySet = settings.value(at: ["plugins", "entries", "weather", "config", "apiKey"]) != nil
    check(settings.plugins.contains { $0.id == "weather" && $0.needsSetup != weatherKeySet }, "plugins.list (\(settings.plugins.map(\.id)))")
    check(!settings.canEdit, "no admin scope by default")
    settings.set(["agents", "defaults", "timeoutSeconds"], 30)
    let readOnly = await settings.save()
    check(!readOnly && settings.saveState.error?.contains("Full Management") == true && settings.hasChanges, "writes need admin access, draft kept")
    settings.discardChanges()

    // Context meter: row snapshot vs limits, and "Compact now" through `/compact` without admin.
    let papersUsage = gateway.contextUsage(for: "agent:research:dashboard:papers")
    check(papersUsage == ContextUsage(used: 96_000, limit: 200_000) && papersUsage?.level == .normal,
          "context usage from the session row (\(papersUsage?.summary ?? "none"))")
    check(gateway.contextUsage(for: "agent:coder:main")?.level == .critical, "nearly full session is critical")
    let researchKey = "agent:research:main"
    check(gateway.defaultContextTokens == 128_000 && gateway.contextUsage(for: researchKey)?.limit == 128_000,
          "sessions.list defaults.contextTokens before the catalog loads")
    check(gateway.needsModelCatalogForContext(researchKey) || gateway.modelCatalogs["research"] != nil, "catalog needed for the limit")
    await gateway.loadModels(agentId: "research")
    check(!gateway.needsModelCatalogForContext(researchKey) && gateway.contextUsage(for: researchKey)?.limit == 200_000,
          "models.list includeDetails contextTokens used as the limit (\(gateway.contextUsage(for: researchKey)?.summary ?? "none"))")
    check(!gateway.canCompactDirectly, "sessions.compact needs admin")
    let coder = gateway.chat(for: "agent:coder:main")
    await coder.load()
    await coder.compact(instructions: "keep the build notes")
    check(coder.compaction?.isRunning == true || coder.compaction != nil, "compaction started")
    let coderCompacted = await waitFor("/compact", timeout: 20) {
        if case .finished = coder.compaction { return !coder.isRunning }
        return false
    }
    check(coderCompacted && coder.compaction == .finished(before: 190_000, after: 34_200),
          "/compact with instructions reports before → after (\(String(describing: coder.compaction)))")
    check(gateway.contextUsage(for: "agent:coder:main")?.used == 34_200, "meter drops after compaction")
    let sawMarker = await waitFor("compaction marker") {
        coder.items.contains { $0.markerKind == "compaction" }
    }
    check(sawMarker, "compaction marker in the transcript")
    coder.clearCompaction()
    check(coder.compaction == nil, "result cleared when the popover closes")
    gateway.stop()

    let adminProfile = GatewayProfile(id: profile.id, name: "Mock", url: url, authMode: .token, access: .admin)
    check(adminProfile.requestedScopes.contains("operator.admin") && !profile.requestedScopes.contains("operator.admin"),
          "admin scope only when opted in")
    let decodedProfile = try? JSONDecoder().decode(GatewayProfile.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","url":"ws://127.0.0.1","authMode":"token"}"#.utf8))
    check(decodedProfile?.access == .standard, "profiles saved before settings support still load")
    let legacyAdmin = try? JSONDecoder().decode(GatewayProfile.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","url":"ws://127.0.0.1","authMode":"token","manageSettings":true}"#.utf8))
    check(legacyAdmin?.access == .admin, "legacy manageSettings → Full Management")
    let reencoded = try? JSONDecoder().decode(GatewayProfile.self, from: JSONEncoder().encode(adminProfile))
    check(reencoded?.access == .admin, "access level round-trips")
    let admin = GatewayStore(profile: adminProfile)
    admin.start()
    let adminConnected = await waitFor("admin connection") { admin.state.isConnected && admin.hello != nil }
    check(adminConnected && admin.settings.canEdit, "admin scope granted")
    let adminAutomations = admin.automations
    await adminAutomations.load()
    check(adminAutomations.canEdit, "admin can edit automations")
    var newJob = CronJobDraft(agentId: "main")
    newJob.name = "Live check"
    newJob.message = "Say hello"
    let createdId = await adminAutomations.save(newJob)
    check(createdId != nil && adminAutomations.job(createdId)?.nextRunAt != nil, "cron.add")
    if let createdId, let created = adminAutomations.job(createdId) {
        await adminAutomations.setEnabled(created, false)
        check(adminAutomations.job(createdId)?.health == .paused, "pause")
        var edit = CronJobDraft(job: adminAutomations.job(createdId)!, defaultAgentId: "main")
        edit.name = "Live check (edited)"
        edit.enabled = true
        let edited = await adminAutomations.save(edit)
        check(edited == createdId && adminAutomations.job(createdId)?.name == "Live check (edited)"
              && adminAutomations.job(createdId)?.enabled == true, "cron.update")
        // A stale revision is refused, then the latest job is loaded.
        let stale = await adminAutomations.save({ var d = edit; d.name = "Stale"; return d }())
        check(stale == nil && adminAutomations.operation(for: createdId).error?.contains("changed on the Gateway") == true,
              "stale edit refused")
        await adminAutomations.runNow(adminAutomations.job(createdId)!)
        let finished = await waitFor("cron run") {
            adminAutomations.runs[createdId]?.first?.status == .ok && adminAutomations.job(createdId)?.health == .ok
        }
        check(finished, "run now → cron event → history (\(adminAutomations.runs[createdId]?.count ?? 0) runs)")
        let runKey = adminAutomations.runs[createdId]?.first?.sessionKey
        check(runKey == "agent:main:cron:\(createdId)", "run links to its chat")
        await adminAutomations.remove(adminAutomations.job(createdId)!)
        check(adminAutomations.job(createdId) == nil, "cron.remove")
    }
    let adminSettings = admin.settings
    await adminSettings.load()
    let hashBefore = adminSettings.snapshot?.hash
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 30)
    check(adminSettings.changeCount == 1 && adminSettings.saveBlocker == nil, "one pending change")
    let hot = await adminSettings.save()
    check(hot && adminSettings.lastSave?.outcome == .applied && !adminSettings.hasChanges,
          "config.patch hot-applied (\(adminSettings.saveState.error ?? "")\(adminSettings.writeIssues.map(\.message)))")
    check(adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 30 && adminSettings.snapshot?.hash != hashBefore,
          "saved value re-read with a new hash")
    let bindValue: JSONValue = adminSettings.value(at: ["gateway", "bind"]) == "lan" ? "tailnet" : "lan"
    adminSettings.set(["gateway", "bind"], bindValue)
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 35)
    let restarting = await adminSettings.save()
    check(restarting && adminSettings.lastSave?.outcome == .restarting
          && adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 35, "several changes in one save; restart reported")
    adminSettings.set(["gateway", "port"], 70000)
    check(adminSettings.saveBlocker == nil || adminSettings.validationProblems["gateway.port"] != nil, "local validation when the schema has bounds")
    if adminSettings.saveBlocker == nil {
        let invalid = await adminSettings.save()
        check(!invalid && adminSettings.writeIssues.first?.path == "gateway.port" && adminSettings.hasChanges,
              "invalid value rejected with its path, draft kept")
        check(!adminSettings.issues(under: ["gateway"]).isEmpty && adminSettings.issues(under: ["agents"]).isEmpty, "issues matched to their section")
    }
    adminSettings.discardChanges()
    check(adminSettings.writeIssues.isEmpty && !adminSettings.hasChanges, "discard clears the draft and issues")
    adminSettings.set(["channels", "discord", "dmPolicy"], "allowlist")
    let keptSecret = await adminSettings.save()
    check(keptSecret && adminSettings.value(at: ["channels", "discord", "dmPolicy"]) == "allowlist"
          && adminSettings.value(at: ["channels", "discord", "token"])?.isRedacted != false, "redacted secret round-trips")
    adminSettings.set(["tools", "allow"], json(#"["exec"]"#))
    let lists = await adminSettings.save()
    check(lists && adminSettings.value(at: ["tools", "allow"]) == json(#"["exec"]"#), "lists replace with replacePaths")

    // Another writer changed the config: unrelated edits are rebased and saved, clashing ones asked about.
    let otherAdminProfile = GatewayProfile(name: "Other admin", url: url, authMode: .token, access: .admin)
    otherAdminProfile.secret = token
    let other2 = GatewayStore(profile: otherAdminProfile)
    other2.start()
    _ = await waitFor("other admin") { other2.state.isConnected && other2.hello != nil }
    await other2.settings.load()
    other2.settings.set(["agents", "defaults", "timeoutSeconds"], 45)
    await other2.settings.save()
    let rebasedModel = JSONValue.string("mock/rebased-\(UUID().uuidString.prefix(6))")
    adminSettings.set(["agents", "defaults", "model"], rebasedModel)
    let rebasedSave = await adminSettings.save()
    check(rebasedSave && adminSettings.value(at: ["agents", "defaults", "model"]) == rebasedModel
          && adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 45, "stale hash → rebased and saved without clobbering")
    other2.settings.set(["agents", "defaults", "timeoutSeconds"], 50)
    await other2.settings.load()
    await other2.settings.save()
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 60)
    let clash = await adminSettings.save()
    check(!clash && adminSettings.conflicts.first?.id == "agents.defaults.timeoutSeconds"
          && adminSettings.conflicts.first?.theirs == 50, "clashing edit becomes a conflict (\(adminSettings.saveState.error ?? ""))")
    if let conflict = adminSettings.conflicts.first { adminSettings.resolve(conflict, keepMine: false) }
    check(adminSettings.conflicts.isEmpty && !adminSettings.hasChanges
          && adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 50, "use the Gateway's value")
    other2.stop()

    if let weather = adminSettings.plugin("weather") {
        await adminSettings.loadCredentials(for: weather)
        check(adminSettings.credentials["weather"]?.first?.path.last == "apiKey", "plugins.inspect credentials")
        adminSettings.set(weather.configPath + ["apiKey"], "short")
        let short = await adminSettings.save()
        let apiKeyId = "plugins.entries.weather.config.apiKey"
        check(!short && (adminSettings.validationProblems[apiKeyId] != nil || adminSettings.writeIssues.first?.path == apiKeyId),
              "plugin config validated")
        adminSettings.set(weather.configPath + ["apiKey"], "weather-key-123")
        await adminSettings.save()
        check(adminSettings.plugin("weather")?.needsSetup == false && adminSettings.value(at: weather.configPath + ["apiKey"])?.isRedacted == true,
              "plugin set up with its credential")
    }
    if let browser = adminSettings.plugin("browser") {
        await adminSettings.setEnabled(browser, true)
        check(adminSettings.pendingConfirmation != nil && adminSettings.plugin("browser")?.enabled == false, "capability consent asked first")
        if let confirmation = adminSettings.pendingConfirmation { await adminSettings.confirm(confirmation) }
        check(adminSettings.plugin("browser")?.enabled == true && adminSettings.pendingConfirmation == nil, "plugin enabled after consent")
        await adminSettings.setEnabled(adminSettings.plugin("browser")!, false)
        check(adminSettings.plugin("browser")?.enabled == false, "plugin disabled")
    }
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 55)
    let installed = await adminSettings.install(from: .npm, spec: "openclaw-plugin-todo@1.0.0")
    check(installed && adminSettings.plugin("todo")?.enabled == true, "plugins.install")
    check(adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 55, "plugin changes keep the unsaved draft")
    adminSettings.discardChanges()
    let unverified = await adminSettings.install(from: .clawhub, spec: "@someone/unverified-thing")
    check(!unverified, "unverified install waits for confirmation")
    if let confirmation = adminSettings.pendingConfirmation { await adminSettings.confirm(confirmation) }
    check(adminSettings.plugin("unverified-thing") != nil, "install after acknowledging the policy warning")
    if let todo = adminSettings.plugin("todo") {
        await adminSettings.uninstall(todo)
        check(adminSettings.plugin("todo") == nil, "plugins.uninstall")
    }
    let missing = await adminSettings.install(from: .npm, spec: "missing-package")
    check(!missing && adminSettings.operation(for: GatewaySettingsModel.installKey).error?.contains("not found") == true,
          "install errors surface")
    check(admin.canCompactDirectly, "admin compacts through sessions.compact")
    let papers = admin.chat(for: "agent:research:dashboard:papers")
    await papers.load()
    await papers.compact()
    check(papers.compaction == .finished(before: 96_000, after: 17_280),
          "sessions.compact reports tokensBefore → tokensAfter (\(String(describing: papers.compaction)))")
    let papersDropped = await waitFor("papers row") { admin.contextUsage(for: "agent:research:dashboard:papers")?.used == 17_280 }
    check(papersDropped, "session row updated after sessions.compact")
    await papers.compact()
    await papers.compact()
    if case let .skipped(reason) = papers.compaction {
        check(reason.contains("Nothing to compact"), "nothing left to compact is reported, not an error")
    } else {
        check(false, "nothing left to compact (\(String(describing: papers.compaction)))")
    }
    admin.stop()

    for store in [gateway, other] {
        for prefix in ["serverNames", "serverNamesSynced", "chatIcons", "chatIconsSynced"] {
            UserDefaults.standard.removeObject(forKey: "pincer.\(prefix).\(store.id.uuidString)")
        }
    }
    gateway.stop()
}
