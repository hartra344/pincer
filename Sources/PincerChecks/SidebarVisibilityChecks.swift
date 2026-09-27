import Foundation
import PincerKit

// #174: automation (`:cron:`) and slash-command (`:slash:`) sessions stay out of the sidebar until
// Organize ▸ Show Automations / Show Slash Commands is on.

private let organizations: [SidebarOrganization] = [.recent, .agent, .group, .servers]

private func sidebarKeys(_ sections: [SidebarSection]) -> Set<String> {
    Set(sections.flatMap { $0.channels.flatMap { [$0.row.key] + $0.threads.map(\.key) } })
}

/// Keys listed in every organization mode, with the mode restored afterwards.
@MainActor
private func keysInEveryMode(_ gateway: GatewayStore, search: String = "") -> [SidebarOrganization: Set<String>] {
    let saved = gateway.organization
    defer { gateway.organization = saved }
    var result: [SidebarOrganization: Set<String>] = [:]
    for organization in organizations {
        gateway.organization = organization
        result[organization] = sidebarKeys(gateway.sections(search: search))
    }
    return result
}

@MainActor
private func serverSections(_ gateway: GatewayStore) -> [SidebarSection] {
    let saved = gateway.organization
    defer { gateway.organization = saved }
    gateway.organization = .servers
    return gateway.sections()
}

/// Unread chats the badge should count: listed, top-level, not archived, not hidden.
@MainActor
private func expectedUnread(_ gateway: GatewayStore) -> Int {
    gateway.sessions.values.filter { row in
        row.isUnread && !row.isArchived && !row.isSubagent
            && !(row.isAutomation && !gateway.showAutomations) && !(row.isSlashCommands && !gateway.showSlashCommands)
    }.count
}

/// The toggles against a connected Gateway that has automation chats (and, if `slashKey` is set, a
/// slash-command chat). Restores the toggles, organization and selection when done.
@MainActor
func checkSidebarVisibility(_ gateway: GatewayStore, automations: [String], slashKey: String?, label: String) async {
    let savedOrganization = gateway.organization
    let savedSelection = gateway.selectedKey
    let savedToggles = (gateway.showAutomations, gateway.showSlashCommands)
    defer {
        gateway.organization = savedOrganization
        gateway.showAutomations = savedToggles.0
        gateway.showSlashCommands = savedToggles.1
    }
    let hiddenKeys = automations + (slashKey.map { [$0] } ?? [])
    let present = await waitFor("\(label): hidden-kind sessions listed") { hiddenKeys.allSatisfy { gateway.sessions[$0] != nil } }
    check(present, "\(label): the Gateway lists the automation and slash-command sessions (\(hiddenKeys))")
    guard present else { return }
    if hiddenKeys.contains(gateway.selectedKey ?? "") { gateway.selectedKey = "agent:main:main" }

    check(!gateway.showAutomations && !gateway.showSlashCommands, "\(label): Show Automations and Show Slash Commands start off")
    check(automations.allSatisfy { gateway.sessions[$0]?.isAutomation == true }
          && slashKey.map { gateway.sessions[$0]?.isSlashCommands == true } != false, "\(label): keys classified as hidden kinds")
    check(hiddenKeys.allSatisfy { gateway.sessions[$0].map(gateway.isHiddenInSidebar) == true }, "\(label): isHiddenInSidebar by default")
    for (organization, keys) in keysInEveryMode(gateway) {
        check(keys.isDisjoint(with: hiddenKeys) && keys.contains("agent:main:main"),
              "\(label): hidden in \(organization) (\(keys.intersection(hiddenKeys)))")
    }
    let hiddenSections = serverSections(gateway)
    check(!hiddenSections.contains { $0.id == "automations" || $0.kind == .automations },
          "\(label): no Automations section by server (\(hiddenSections.map(\.id)))")
    check(!hiddenSections.contains { $0.channels.isEmpty }, "\(label): no empty sections left behind by server")

    // The badge and section counts skip hidden chats.
    check(gateway.totalUnread == expectedUnread(gateway), "\(label): totalUnread skips hidden chats (\(gateway.totalUnread))")
    let sectionUnread = hiddenSections.reduce(0) { $0 + $1.unreadCount }
    check(sectionUnread <= gateway.totalUnread, "\(label): section unread counts skip hidden chats (\(sectionUnread))")

    // A search still finds them.
    for key in hiddenKeys {
        guard let title = gateway.sessions[key]?.title else { continue }
        for (organization, keys) in keysInEveryMode(gateway, search: title) {
            check(keys.contains(key), "\(label): searching “\(title)” finds \(key) in \(organization)")
        }
    }

    // Show Automations brings them back, with the Automations section by server.
    let before = gateway.totalUnread
    gateway.showAutomations = true
    check(automations.allSatisfy { gateway.sessions[$0].map(gateway.isHiddenInSidebar) == false }
          && slashKey.map { gateway.sessions[$0].map(gateway.isHiddenInSidebar) == true } != false,
          "\(label): Show Automations shows only automations")
    for (organization, keys) in keysInEveryMode(gateway) {
        check(keys.isSuperset(of: automations) && slashKey.map { !keys.contains($0) } != false,
              "\(label): automations listed in \(organization)")
    }
    let shown = serverSections(gateway)
    check(Set(shown.first { $0.id == "automations" }?.channels.map(\.row.key) ?? []).isSuperset(of: automations)
          && shown.last?.id == "automations", "\(label): Automations section by server (\(shown.map(\.id)))")
    let unreadAutomations = automations.filter { gateway.sessions[$0]?.isUnread == true }.count
    // Live Gateways can mark chats unread meanwhile, so compare against the rows as they are now.
    check(gateway.totalUnread == expectedUnread(gateway) && (unreadAutomations == 0 || gateway.totalUnread > 0),
          "\(label): unread automations count once shown (\(before) → \(gateway.totalUnread))")
    if unreadAutomations > 0 {
        check((shown.first { $0.id == "automations" }?.unreadCount ?? 0) == unreadAutomations,
              "\(label): the Automations section counts its unread chats")
    }

    if let slashKey {
        gateway.showAutomations = false
        gateway.showSlashCommands = true
        for (organization, keys) in keysInEveryMode(gateway) {
            check(keys.contains(slashKey) && keys.isDisjoint(with: automations), "\(label): slash commands listed in \(organization)")
        }
        check(!serverSections(gateway).contains { $0.id == "automations" }, "\(label): Show Slash Commands alone adds no Automations section")
        gateway.showSlashCommands = false
    }
    gateway.showAutomations = false
    check(sidebarKeys(gateway.sections()).isDisjoint(with: hiddenKeys) && gateway.totalUnread == expectedUnread(gateway),
          "\(label): turning them off hides them again")

    // The open chat always shows, even a hidden kind.
    if let selected = automations.first {
        gateway.selectedKey = selected
        check(gateway.sessions[selected].map(gateway.isHiddenInSidebar) == false, "\(label): the selected automation isn't hidden")
        for (organization, keys) in keysInEveryMode(gateway) {
            check(keys.contains(selected) && keys.isDisjoint(with: hiddenKeys.filter { $0 != selected }),
                  "\(label): the selected automation stays listed in \(organization)")
        }
        check(serverSections(gateway).first { $0.id == "automations" }?.channels.map(\.row.key) == [selected],
              "\(label): by server, the Automations section holds just the open automation")
    }
    if let slashKey {
        gateway.selectedKey = slashKey
        check(sidebarKeys(gateway.sections()).contains(slashKey) && !sidebarKeys(gateway.sections()).isSuperset(of: automations),
              "\(label): the selected slash-command chat stays listed, the automation it replaced hides")
    }
    gateway.selectedKey = savedSelection.flatMap { hiddenKeys.contains($0) ? nil : $0 } ?? "agent:main:main"
    check(sidebarKeys(gateway.sections()).isDisjoint(with: hiddenKeys), "\(label): leaving the chat hides it again")
}

/// Demo: the seeded automation and slash-command chats, preferences per Gateway, and the menu bar.
@MainActor
func runDemoSidebarVisibility() async {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let briefing = "agent:main:cron:morning-briefing", disk = "agent:main:cron:disk-check"
    let slash = "agent:main:discord:slash:418235907214753792"
    let app = AppModel(defaults: defaults)
    let gateway = app.add(.demo(), secret: nil)
    let automationsKey = "pincer.showAutomations.\(gateway.id.uuidString)"
    let slashKey = "pincer.showSlashCommands.\(gateway.id.uuidString)"
    let ready = await waitFor("demo for sidebar visibility") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "sidebar visibility demo connected")
    guard ready else {
        for gateway in app.gateways { app.remove(gateway.id) }
        return
    }

    // Seeds: two automations (one unread) and a Discord slash-command session.
    let rows = [briefing, disk, slash].compactMap { gateway.sessions[$0] }
    check(rows.count == 3 && rows[0].title == "Morning briefing" && rows[1].title == "Check disk space"
          && rows[2].title == "Slash commands", "demo seeds automations and slash commands (\(rows.map(\.title)))")
    check(rows.first?.isUnread == true, "the morning briefing is unread")
    check(defaults.object(forKey: automationsKey) == nil && defaults.object(forKey: slashKey) == nil,
          "nothing stored before the toggles change")
    gateway.showAutomations = false
    gateway.showSlashCommands = false
    check(defaults.object(forKey: automationsKey) == nil && defaults.object(forKey: slashKey) == nil,
          "setting the same value stores nothing")

    // The menu bar agrees with the sidebar and the dock badge.
    let menu = MenuBarInbox(app: app)
    check(!menu.unread.contains { $0.target.sessionKey == briefing } && menu.unreadCount == gateway.totalUnread,
          "menu bar leaves hidden automations out of Unread (\(menu.unread.map(\.title)), \(menu.unreadCount) vs \(gateway.totalUnread))")

    let badge = gateway.totalUnread
    gateway.showAutomations = true
    check(gateway.totalUnread == badge + 1, "the unread morning briefing joins the badge once shown (\(badge) → \(gateway.totalUnread))")
    gateway.showAutomations = false
    check(gateway.totalUnread == badge, "…and leaves it once hidden")

    await checkSidebarVisibility(gateway, automations: [briefing, disk], slashKey: slash, label: "demo")

    // Per-Gateway preferences survive a relaunch.
    gateway.showAutomations = true
    check(defaults.object(forKey: automationsKey) as? Bool == true && defaults.object(forKey: slashKey) as? Bool == false,
          "Show Automations stored per Gateway")
    let relaunched = AppModel(defaults: defaults).gateways.first { $0.id == gateway.id }
    check(relaunched?.showAutomations == true && relaunched?.showSlashCommands == false, "Show Automations restored on relaunch")
    gateway.showAutomations = false
    gateway.showSlashCommands = true
    check(defaults.object(forKey: automationsKey) as? Bool == false && defaults.object(forKey: slashKey) as? Bool == true,
          "turning a toggle off stores false")
    let again = AppModel(defaults: defaults).gateways.first { $0.id == gateway.id }
    check(again?.showAutomations == false && again?.showSlashCommands == true, "Show Slash Commands restored on relaunch")
    let other = app.add(GatewayProfile(name: "Other", url: "ws://127.0.0.1:1", authMode: .none), secret: nil)
    check(!other.showAutomations && !other.showSlashCommands, "another Gateway keeps its own defaults")
    gateway.showSlashCommands = false
    check(MenuBarInbox(app: app).unreadCount == gateway.totalUnread, "menu bar unread matches the badge after toggling")

    for gateway in app.gateways { app.remove(gateway.id) }
}
