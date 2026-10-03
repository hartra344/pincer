import Foundation
import PincerKit

@MainActor
func runDemoSlashSuggestionAnnouncementChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("slash announcement Demo connection", timeout: 25) {
        gateway.state.isConnected && !gateway.sessions.isEmpty
    }
    check(connected, "slash announcements connect to the seeded Demo")
    guard connected else { return }
    let key = "agent:main:dashboard:trip"
    let chat = gateway.chat(for: key)
    await chat.load()
    await gateway.loadCommands(sessionKey: key, agentId: "main")
    let commands = gateway.slashCommands(for: key)
    let help = SlashCompletion.suggestions(for: "/help", commands: commands)
    check(help.count == 1 && help.first.map(SlashSuggestionAnnouncement.selected) == "/help", "actual Demo command catalog supplies the selected spoken command")
    check(SlashSuggestionAnnouncement.count(help.count) == "1 command suggestion", "actual one-result query gets the singular count")
    let none = SlashCompletion.suggestions(for: "/zzzz_no_command", commands: commands)
    check(none.isEmpty && SlashSuggestionAnnouncement.count(none.count) == "0 command suggestions", "actual unmatched query announces zero results")
    let choices = SlashCompletion.suggestions(for: "/think ", commands: commands) { _, _, arg in
        if let arg, !arg.choices.isEmpty { return arg.choices }
        return SlashCommand.fallbackThinkingLevels.map { SlashCommandChoice(value: $0) }
    }
    check(!choices.isEmpty && choices.count <= SlashCompletion.limit, "actual Demo completion engine supplies bounded argument choices")
    if let selected = choices.first {
        check(!SlashSuggestionAnnouncement.selected(selected).isEmpty, "actual selected argument has a spoken choice label")
    }
}
