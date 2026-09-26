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
      {"key":"agent:main:cron:nightly","label":"Automation: Nightly","updatedAt":150},
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
        // Pinned first, then the main chat, then by activity; archived hidden; subagent nested.
        #expect(sections[0].channels.map(\.id) == [
            "agent:main:dashboard:budget", "agent:main:main", "agent:main:dashboard:trip",
            "agent:main:discord:channel:123", "agent:research:dashboard:papers", "agent:main:cron:nightly",
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
        #expect(sections.map(\.id) == ["agent:main", "agent:research", "server:discord:guild1", "group:Travel", "automations"])
        let layout = self.layout(sections)
        #expect(layout["agent:main"] == ["agent:main:dashboard:budget", "agent:main:main"])
        #expect(layout["server:discord:guild1"] == ["agent:main:discord:channel:123"])
        #expect(layout["automations"] == ["agent:main:cron:nightly"])
        #expect(sections[2].title == "My Guild")
        #expect(sections[2].kind == .server(ChatServer(provider: "discord", id: "guild1", name: "My Guild")))
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
