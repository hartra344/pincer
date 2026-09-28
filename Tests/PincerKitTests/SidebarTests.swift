import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Sidebar grouping")
struct SidebarTests {
    static let sessions: JSONValue = Fixtures.json(#"""
    {"sessions":[
      {"key":"agent:main:main","updatedAt":100},
      {"key":"agent:main:dashboard:trip","label":"Trip","category":"Travel","updatedAt":300},
      {"key":"agent:main:dashboard:budget","label":"Budget","pinned":true,"updatedAt":50},
      {"key":"agent:main:subagent:abc","label":"Research step","spawnedBy":"agent:main:dashboard:trip","updatedAt":400},
      {"key":"agent:research:dashboard:papers","label":"Papers","updatedAt":200},
      {"key":"agent:main:discord:channel:123","kind":"group","channel":"discord","space":"guild1",
       "groupChannel":"#general","origin":{"label":"My Guild #general channel id:123"},"updatedAt":250},
      {"key":"agent:main:cron:nightly","label":"Automation: Nightly","unread":true,"updatedAt":150},
      {"key":"agent:main:subagent:night","label":"Nightly helper","spawnedBy":"agent:main:cron:nightly:run:r1","updatedAt":155},
      {"key":"agent:main:discord:slash:42","channel":"discord","unread":true,"updatedAt":120},
      {"key":"agent:main:dashboard:old","label":"Old","archived":true,"updatedAt":500}
    ]}
    """#)

    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)

    func store() -> GatewayStore {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        store.applySnapshot(Self.sessions)
        return store
    }

    func layout(_ sections: [SidebarSection]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.channels.map(\.id)) })
    }

    @Test func recent() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.organization = .recent
        let sections = store.sections()
        #expect(sections.map(\.id) == ["recent"])
        // Pinned first, then the main chat, then by activity; archived, automations and slash commands
        // hidden; subagent nested.
        #expect(sections[0].channels.map(\.id) == [
            "agent:main:dashboard:budget", "agent:main:main", "agent:main:dashboard:trip",
            "agent:main:discord:channel:123", "agent:research:dashboard:papers",
        ])
        let trip = sections[0].channels.first { $0.id == "agent:main:dashboard:trip" }
        #expect(trip?.threads.map(\.key) == ["agent:main:subagent:abc"])
    }

    @Test func search() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.organization = .recent
        #expect(store.sections(search: " PAPERS ").first?.channels.map(\.id) == ["agent:research:dashboard:papers"])
        // While searching, subagents are listed on their own rather than nested.
        let research = store.sections(search: "research step").first?.channels
        #expect(research?.map(\.id) == ["agent:main:subagent:abc"] && research?.first?.threads.isEmpty == true)
        #expect(store.sections(search: "zzz").first?.channels.isEmpty == true)
    }

    @Test func byAgent() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.organization = .agent
        let sections = store.sections()
        #expect(sections.map(\.id) == ["agent:main", "agent:research"])
        #expect(sections.map(\.title) == ["Main", "Research"])
        #expect(sections[1].channels.map(\.id) == ["agent:research:dashboard:papers"])
        #expect(sections[0].kind == .agent("main"))
    }

    @Test func byGroup() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.organization = .group
        let sections = store.sections()
        #expect(sections.map(\.id) == ["group:Travel", "group:"])
        #expect(sections[0].channels.map(\.id) == ["agent:main:dashboard:trip"] && sections[0].kind == .group("Travel"))
        #expect(sections[1].title == "Ungrouped" && !sections[1].channels.contains { $0.id == "agent:main:dashboard:trip" })
    }

    @Test func byServer() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.organization = .servers
        let sections = store.sections()
        #expect(sections.map(\.id) == ["agent:main", "agent:research", "server:discord:guild1", "group:Travel"])
        var layout = self.layout(sections)
        #expect(layout["agent:main"] == ["agent:main:dashboard:budget", "agent:main:main"])
        #expect(layout["server:discord:guild1"] == ["agent:main:discord:channel:123"])
        store.showAutomations = true
        let shown = store.sections()
        #expect(shown.map(\.id) == ["agent:main", "agent:research", "server:discord:guild1", "group:Travel", "automations"])
        layout = self.layout(shown)
        #expect(layout["automations"] == ["agent:main:cron:nightly"])
        #expect(sections[2].title == "My Guild")
        #expect(sections[2].kind == .server(ChatServer(provider: "discord", id: "guild1", name: "My Guild")))
    }

    static let automation = "agent:main:cron:nightly"
    static let automationHelper = "agent:main:subagent:night"
    static let slash = "agent:main:discord:slash:42"
    static let hiddenKinds: Set<String> = [automation, automationHelper, slash]

    /// Every key listed (top level and threads) in each organization mode.
    func keysByMode(_ store: GatewayStore, search: String = "") -> [SidebarOrganization: Set<String>] {
        var result: [SidebarOrganization: Set<String>] = [:]
        for organization in [SidebarOrganization.recent, .agent, .group, .servers] {
            store.organization = organization
            result[organization] = Set(store.sections(search: search).flatMap { [$0.id] + $0.channels.flatMap { [$0.id] + $0.threads.map(\.key) } })
        }
        return result
    }

    @Test func automationsAndSlashCommandsHiddenByDefault() throws {
        defer { self.scratch.remove() }
        let store = self.store()
        #expect(!store.showAutomations && !store.showSlashCommands)
        let automation = try #require(store.sessions[Self.automation])
        let slash = try #require(store.sessions[Self.slash])
        #expect(store.isHiddenInSidebar(automation) && store.isHiddenInSidebar(slash))
        #expect(!store.isHiddenInSidebar(try #require(store.sessions["agent:main:main"])))
        for (organization, keys) in self.keysByMode(store) {
            #expect(keys.isDisjoint(with: Self.hiddenKinds), "\(organization) lists \(keys.intersection(Self.hiddenKinds))")
            #expect(!keys.contains("automations"), "\(organization) has an Automations section")
            #expect(keys.contains("agent:main:main"))
        }
    }

    @Test func showAutomations() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.showAutomations = true
        #expect(!store.isHiddenInSidebar(store.sessions[Self.automation]!) && store.isHiddenInSidebar(store.sessions[Self.slash]!))
        for (organization, keys) in self.keysByMode(store) {
            #expect(keys.isSuperset(of: [Self.automation, Self.automationHelper]) && !keys.contains(Self.slash), "\(organization)")
        }
        store.organization = .recent
        // The run's subagent nests under its automation again.
        let nightly = store.sections()[0].channels.first { $0.id == Self.automation }
        #expect(nightly?.threads.map(\.key) == [Self.automationHelper])
        store.organization = .servers
        let last = store.sections().last
        #expect(last?.id == "automations" && last?.kind == .automations && last?.channels.map(\.id) == [Self.automation])
    }

    @Test func showSlashCommands() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.showSlashCommands = true
        for (organization, keys) in self.keysByMode(store) {
            #expect(keys.contains(Self.slash) && keys.isDisjoint(with: [Self.automation, Self.automationHelper]), "\(organization)")
        }
        store.organization = .servers
        let sections = store.sections()
        // A slash-command session isn't a server channel, so it sits with its agent's chats.
        #expect(!sections.contains { $0.id == "automations" })
        #expect(self.layout(sections)["agent:main"]?.contains(Self.slash) == true)
    }

    @Test func selectedHiddenChatStaysListed() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.selectedKey = Self.automation
        #expect(!store.isHiddenInSidebar(store.sessions[Self.automation]!))
        for (organization, keys) in self.keysByMode(store) {
            #expect(keys.contains(Self.automation) && !keys.contains(Self.slash), "\(organization)")
        }
        store.organization = .servers
        #expect(self.layout(store.sections())["automations"] == [Self.automation])
        store.selectedKey = Self.slash
        #expect(store.isHiddenInSidebar(store.sessions[Self.automation]!) && !store.isHiddenInSidebar(store.sessions[Self.slash]!))
        for (organization, keys) in self.keysByMode(store) {
            #expect(keys.contains(Self.slash) && !keys.contains(Self.automation), "\(organization)")
        }
    }

    @Test func searchFindsHiddenKinds() {
        defer { self.scratch.remove() }
        let store = self.store()
        for (organization, keys) in self.keysByMode(store, search: "nightly") {
            #expect(keys.isSuperset(of: [Self.automation, Self.automationHelper]), "\(organization)")
        }
        for (organization, keys) in self.keysByMode(store, search: "Slash commands") {
            #expect(keys.contains(Self.slash), "\(organization)")
        }
        store.organization = .recent
        #expect(store.sections(search: "  ").first?.channels.contains { Self.hiddenKinds.contains($0.id) } == false,
                "a blank search is no search")
    }

    @Test func unreadSkipsHiddenKinds() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.organization = .servers
        #expect(store.totalUnread == 0)
        #expect(store.sections().allSatisfy { $0.unreadCount == 0 })
        store.showAutomations = true
        #expect(store.totalUnread == 1)
        #expect(store.sections().first { $0.id == "automations" }?.unreadCount == 1)
        store.showSlashCommands = true
        #expect(store.totalUnread == 2)
        #expect(store.sections().first { $0.id == "agent:main" }?.unreadCount == 1)
        store.showAutomations = false
        store.showSlashCommands = false
        store.selectedKey = Self.slash
        #expect(store.totalUnread == 1, "the open chat is listed, so it counts")
    }

    @Test func visibilityPreferencesPersistPerGateway() {
        defer { self.scratch.remove() }
        let automationsKey = "pincer.showAutomations.\(self.profile.id.uuidString)"
        let slashKey = "pincer.showSlashCommands.\(self.profile.id.uuidString)"
        let store = self.store()
        store.showAutomations = false
        store.showSlashCommands = false
        #expect(self.scratch.defaults.object(forKey: automationsKey) == nil && self.scratch.defaults.object(forKey: slashKey) == nil,
                "unchanged values aren't written")
        store.showAutomations = true
        #expect(self.scratch.defaults.object(forKey: automationsKey) as? Bool == true)
        #expect(self.scratch.defaults.object(forKey: slashKey) == nil)
        #expect(UserDefaults.standard.object(forKey: automationsKey) == nil)
        var relaunched = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        #expect(relaunched.showAutomations && !relaunched.showSlashCommands)
        store.showAutomations = false
        store.showSlashCommands = true
        #expect(self.scratch.defaults.object(forKey: automationsKey) as? Bool == false)
        relaunched = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        #expect(!relaunched.showAutomations && relaunched.showSlashCommands)
        let other = GatewayStore(profile: GatewayProfile(name: "Other", url: "ws://127.0.0.1:2", authMode: .none),
                                 defaults: self.scratch.defaults, identity: Fixtures.identity())
        #expect(!other.showAutomations && !other.showSlashCommands)
    }

    @Test func groupDropValue() throws {
        defer { self.scratch.remove() }
        let store = self.store()
        let trip = "agent:main:dashboard:trip"
        let main = "agent:main:main"
        let travel = SidebarSection(id: "group:Travel", title: "Travel", emoji: nil, channels: [], kind: .group("Travel"))
        let work = SidebarSection(id: "group:Work", title: "Work", emoji: nil, channels: [], kind: .group("Work"))
        let ungrouped = SidebarSection(id: "group:", title: "Ungrouped", emoji: nil, channels: [], kind: .other)
        let recent = SidebarSection(id: "recent", title: "Recent", emoji: nil, channels: [], kind: .other)
        let mainAgent = SidebarSection(id: "agent:main", title: "Main", emoji: nil, channels: [], kind: .agent("main"))
        let research = SidebarSection(id: "agent:research", title: "Research", emoji: nil, channels: [], kind: .agent("research"))

        store.organization = .group
        #expect(absent(store.groupDropValue(for: trip, onto: travel)))
        #expect(store.groupDropValue(for: trip, onto: work) == .string("Work"))
        #expect(store.groupDropValue(for: main, onto: work) == .string("Work"))
        #expect(store.groupDropValue(for: trip, onto: ungrouped) == .null)
        #expect(absent(store.groupDropValue(for: main, onto: ungrouped)))
        #expect(absent(store.groupDropValue(for: trip, onto: recent)))
        #expect(absent(store.groupDropValue(for: trip, onto: mainAgent)), "agent sections only ungroup when organized by server")
        #expect(absent(store.groupDropValue(for: "agent:main:subagent:abc", onto: work)))
        #expect(absent(store.groupDropValue(for: "agent:nope:missing", onto: work)))

        store.organization = .servers
        #expect(store.groupDropValue(for: trip, onto: mainAgent) == .null)
        #expect(absent(store.groupDropValue(for: trip, onto: research)))
        #expect(absent(store.groupDropValue(for: main, onto: mainAgent)))
    }

    @Test func preferencesUseInjectedDefaults() {
        defer { self.scratch.remove() }
        let key = "pincer.org.v2.\(self.profile.id.uuidString)"
        let store = self.store()
        store.organization = .agent
        store.setSectionCollapsed("agent:main", true)
        #expect(self.scratch.defaults.string(forKey: key) == "agent")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        let relaunched = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        #expect(relaunched.organization == .agent)
        #expect(relaunched.collapsedSections.contains("agent:main"))
        #expect(relaunched.deviceId == Fixtures.deviceId)
    }
}
