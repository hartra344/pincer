import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

/// "Gateway config schema", "Gateway config values" and "Gateway config feedback" (headers print here: they share the schema and sample config).
@MainActor
func runConfigChecks() {
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
    check(ConfigApplyOutcome(pluginChange: json(#"{"ok":true,"restartRequired":true}"#)) == .restartRequired, "plugin restart needed")

    let plugin = PluginInfo(json(#"{"id":"weather","name":"Weather","installed":true,"enabled":true,"state":"needs-setup","origin":"clawhub","runtime":{"state":"disabled"}}"#))
    check(plugin?.needsSetup == true && plugin?.statusLabel == "Needs setup" && plugin?.removable == true, "plugin entry")
    check(PluginInfo(json(#"{"id":"b","name":"B","installed":true,"enabled":false,"state":"disabled","origin":"bundled"}"#))?.removable == false,
          "bundled plugins aren't removable by default")
    let credential = PluginCredential(json(#"{"path":["plugins","entries","weather","config","apiKey"],"label":"API key","envVars":["WEATHER_KEY"],"signupUrl":"http://x","requiresCredential":true}"#))
    check(credential?.path.last == "apiKey" && credential?.isRequired == true && credential?.signupURL == nil, "plugin credential (non-https signup dropped)")
    check(PluginCredential(json(#"{"path":["a","b",0,"c","d"],"label":"x","envVars":[]}"#)) == nil, "array credential paths skipped")
}
