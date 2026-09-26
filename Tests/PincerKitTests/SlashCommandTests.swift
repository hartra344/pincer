import Foundation
import Testing
@testable import PincerKit

@Suite("Slash commands")
struct SlashCommandTests {
    static let catalog = Fixtures.json(#"""
    {"commands":[
      {"name":"think","textAliases":["/think","/Thinking","/t","/think"],"description":"Set thinking level.",
       "category":"options","source":"native","acceptsArgs":true,
       "args":[{"name":"level","description":"Level","required":true,"choices":["low",{"value":"high","label":"High"},{"label":"no value"}]}]},
      {"name":"menu","scope":"native","description":"Discord-only menu"},
      {"name":"help","description":"Show help."},
      {"name":"help","description":"Duplicate"},
      {"name":"bad name"},
      {"textAliases":["/skill-run"],"source":"skill","description":"Run a skill"},
      {"description":"no name"}
    ]}
    """#)

    @Test func parse() {
        let commands = SlashCommand.parse(Self.catalog)
        #expect(commands.map(\.name) == ["think", "help", "skill-run"])
        let think = commands[0]
        #expect(think.aliases == ["thinking", "t"])
        #expect(think.matches("THINKING") && think.matches("t") && !think.matches("th"))
        #expect(think.acceptsArgs && think.category == "options" && think.source == "native")
        #expect(think.args.first?.isRequired == true && think.usage == "<level>")
        #expect(think.args.first?.choices == [SlashCommandChoice(value: "low"), SlashCommandChoice(value: "high", label: "High")])
        #expect(commands[1].description == "Show help." && !commands[1].acceptsArgs)
        #expect(commands[2].source == "skill")
        #expect(SlashCommand.parse([:]).isEmpty)
    }

    @Test func clientCommands() {
        let gateway = SlashCommand.parse(Self.catalog)
        let merged = SlashCommand.withClientCommands(gateway)
        #expect(merged.map(\.name) == ["think", "help", "skill-run", "clear"])
        #expect(merged.last?.source == "client")
        let nativeClear = SlashCommand(name: "clear", description: "Gateway clear")
        #expect(SlashCommand.withClientCommands([nativeClear]) == [nativeClear])
    }

    @Test func outgoingText() {
        let commands = SlashCommand.withClientCommands(SlashCommand.fallback)
        #expect(SlashCommand.outgoingText("/clear", commands: commands) == "/reset")
        #expect(SlashCommand.outgoingText("  /CLEAR \n", commands: commands) == "/reset")
        #expect(SlashCommand.outgoingText("/clear now", commands: commands) == "/clear now")
        #expect(SlashCommand.outgoingText("please /clear", commands: commands) == "please /clear")
        #expect(SlashCommand.outgoingText("/reset", commands: commands) == "/reset")
        #expect(SlashCommand.outgoingText("hello", commands: commands) == "hello")
        // A Gateway that has its own /clear gets it verbatim.
        let native = [SlashCommand(name: "clear", description: "Gateway clear")]
        #expect(SlashCommand.outgoingText("/clear", commands: native) == "/clear")
    }
}

@Suite("Slash completion")
struct SlashCompletionTests {
    let commands = SlashCommand.withClientCommands(SlashCommand.fallback)

    func names(_ text: String) -> [String] {
        SlashCompletion.suggestions(for: text, commands: self.commands).map { suggestion in
            switch suggestion.kind {
            case let .command(command): command.name
            case let .argument(choice, _, _): choice.value
            }
        }
    }

    @Test func commandRanking() {
        #expect(self.names("/") == self.commands.map(\.name))
        #expect(self.names("/t").first == "think") // exact alias beats prefixes
        #expect(self.names("/th") == ["think"])
        #expect(self.names("/sta") == ["status", "restart", "new"]) // prefix, substring, description
        #expect(self.names("/ode").contains("models") && self.names("/ode").first == "model")
        // Description matches rank last and need three characters.
        #expect(self.names("/session") == ["new", "reset", "compact", "name"])
        #expect(self.names("/nothing-like-this").isEmpty)
        #expect(self.names("hello").isEmpty && self.names("/a\nb").isEmpty && self.names("/a/b").isEmpty)
    }

    @Test func replacements() {
        let think = SlashCompletion.suggestions(for: "/thi", commands: self.commands)
        #expect(think.first?.replacement == "/think ")
        let help = SlashCompletion.suggestions(for: "/hel", commands: self.commands)
        #expect(help.first?.replacement == "/help")
        #expect(help.first?.isComplete(for: "/help ") == true && help.first?.isComplete(for: "/hel") == false)
    }

    @Test func argumentChoices() {
        #expect(self.names("/verbose ") == ["on", "off", "full"])
        #expect(self.names("/verbose o") == ["on", "off"])
        #expect(self.names("/verbose FU") == ["full"])
        #expect(SlashCompletion.suggestions(for: "/verbose o", commands: self.commands).first?.replacement == "/verbose on")
        #expect(self.names("/help x").isEmpty, "commands without arguments offer nothing")
        #expect(self.names("/unknown x").isEmpty)
    }

    @Test func dynamicChoices() {
        let models = [SlashCommandChoice(value: "anthropic/claude-opus-4", detail: "Anthropic"),
                      SlashCommandChoice(value: "openai/gpt-5", label: "GPT-5")]
        let suggestions = SlashCompletion.suggestions(for: "/model gpt", commands: self.commands) { command, index, _ in
            command.name == "model" && index == 0 ? models : []
        }
        #expect(suggestions.map(\.replacement) == ["/model openai/gpt-5"])
        let all = SlashCompletion.suggestions(for: "/model ", commands: self.commands) { _, _, _ in models }
        #expect(all.count == 2)
        let opus = SlashCompletion.suggestions(for: "/model opus", commands: self.commands) { _, _, _ in models }
        #expect(opus.map(\.replacement) == ["/model anthropic/claude-opus-4"])
    }

    @Test func limit() {
        let many = (0..<80).map { SlashCommand(name: "cmd\($0)", description: "") }
        #expect(SlashCompletion.suggestions(for: "/cmd", commands: many).count == SlashCompletion.limit)
    }
}
