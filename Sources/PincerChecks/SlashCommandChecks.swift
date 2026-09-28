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

@MainActor
func runSlashCommandChecks() {
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
}
