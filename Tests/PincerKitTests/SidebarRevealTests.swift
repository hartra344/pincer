import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Sidebar reveal and group collapse")
struct SidebarRevealTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)

    func store(_ rows: [(key: String, category: String?, parent: String?)], groups: [String] = []) -> GatewayStore {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        let items = rows.enumerated().map { index, row -> String in
            var fields = #""key":"\#(row.key)","label":"\#(row.key)","updatedAt":\#(1000 + index)"#
            if let category = row.category { fields += #","category":"\#(category)""# }
            if let parent = row.parent { fields += #","spawnedBy":"\#(parent)""# }
            return "{\(fields)}"
        }
        store.applySnapshot(Fixtures.json(#"{"sessions":[\#(items.joined(separator: ","))]}"#))
        store.groupCatalog = groups
        return store
    }

    // MARK: collapse state follows group renames and deletes

    func collapsed(_ ids: [String]) -> [String: Bool] { Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }) }

    @Test func moveCarriesBothKeyShapes() {
        defer { self.scratch.remove() }
        let store = self.store([])
        store.sectionCollapse = ["group:Work": true, "agent:a/group:Work": true, "agent:b/group:Work": false, "agent:a": true]
        store.moveSectionCollapse(fromGroup: "Work", toGroup: "Jobs")
        #expect(store.sectionCollapse == ["group:Jobs": true, "agent:a/group:Jobs": true, "agent:b/group:Jobs": false, "agent:a": true])
    }

    @Test func moveMatchesExactNameOnly() {
        defer { self.scratch.remove() }
        let store = self.store([])
        let before = ["group:Work Stuff": true, "agent:x/group:Work Stuff": true, "group:Network": true, "agent:work": true]
        store.sectionCollapse = before
        store.moveSectionCollapse(fromGroup: "Work", toGroup: "Jobs")
        #expect(store.sectionCollapse == before)
        store.dropSectionCollapse(forGroup: "Work")
        #expect(store.sectionCollapse == before)
    }

    @Test func moveKeepsDestinationValue() {
        defer { self.scratch.remove() }
        let store = self.store([])
        store.sectionCollapse = ["group:Work": true, "group:Jobs": false, "agent:a/group:Work": true]
        store.moveSectionCollapse(fromGroup: "Work", toGroup: "Jobs")
        #expect(store.sectionCollapse == ["group:Jobs": false, "agent:a/group:Jobs": true])
    }

    @Test func dropForgetsBothKeyShapes() {
        defer { self.scratch.remove() }
        let store = self.store([])
        store.sectionCollapse = ["group:Work": true, "agent:a/group:Work": true, "group:Other": true]
        store.dropSectionCollapse(forGroup: "Work")
        #expect(store.sectionCollapse == ["group:Other": true])
    }

    @Test func legacyRenameAndDeleteMoveCollapse() async {
        defer { self.scratch.remove() }
        let store = self.store([("agent:a:dashboard:1", "Work", nil)])
        store.groupCatalogUnsupported = true
        store.sectionCollapse = ["group:Work": true, "agent:a/group:Work": true]
        await store.renameGroup("Work", to: "Jobs")
        #expect(store.sectionCollapse == ["group:Jobs": true, "agent:a/group:Jobs": true])
        await store.deleteGroup("Jobs")
        #expect(store.sectionCollapse.isEmpty)
    }

    @Test func failedCatalogRenameKeepsCollapse() async {
        defer { self.scratch.remove() }
        let store = self.store([], groups: ["Work"])
        #expect(store.usesGroupCatalog)
        store.sectionCollapse = ["group:Work": true]
        await store.renameGroup("Work", to: "Jobs")
        #expect(store.sectionCollapse == ["group:Work": true])
        await store.deleteGroup("Work")
        #expect(store.sectionCollapse == ["group:Work": true])
    }

    // MARK: reveal

    @Test func byAgentNestedGroupRevealsBothLevels() {
        defer { self.scratch.remove() }
        let key = "agent:a:dashboard:1"
        let store = self.store([(key, "Work", nil), ("agent:a:dashboard:2", nil, nil)], groups: ["Work"])
        store.organization = .agent
        #expect(store.sidebarAncestors(of: key) == ["agent:a", "agent:a/group:Work"])
        store.sectionCollapse = ["agent:a": true, "agent:a/group:Work": true]
        #expect(store.revealInSidebar(key))
        #expect(!store.collapsedSections.contains("agent:a") && !store.collapsedSections.contains("agent:a/group:Work"))
        #expect(!store.revealInSidebar(key))
    }

    @Test func byAgentUngroupedChatHasOneAncestor() {
        defer { self.scratch.remove() }
        let store = self.store([("agent:a:dashboard:1", nil, nil)])
        store.organization = .agent
        #expect(store.sidebarAncestors(of: "agent:a:dashboard:1") == ["agent:a"])
        store.sectionCollapse = ["agent:a": true]
        #expect(store.revealInSidebar("agent:a:dashboard:1"))
        #expect(!store.collapsedSections.contains("agent:a"))
    }

    @Test func byGroupAndServerFindTheGroupSection() {
        defer { self.scratch.remove() }
        let key = "agent:a:dashboard:1"
        let store = self.store([(key, "Work", nil)], groups: ["Work"])
        for organization in [SidebarOrganization.group, .servers] {
            store.organization = organization
            store.sectionCollapse = ["group:Work": true]
            #expect(store.sidebarAncestors(of: key) == ["group:Work"])
            #expect(store.revealInSidebar(key))
            #expect(!store.collapsedSections.contains("group:Work"))
        }
    }

    @Test func recentAndUnknownKeysHaveNoAncestors() {
        defer { self.scratch.remove() }
        let store = self.store([("agent:a:dashboard:1", nil, nil)])
        store.organization = .recent
        store.sectionCollapse = ["recent": true, "agent:a": true]
        #expect(store.sidebarAncestors(of: "agent:a:dashboard:1").isEmpty)
        #expect(!store.revealInSidebar("agent:a:dashboard:1"))
        store.organization = .agent
        #expect(store.sidebarAncestors(of: "nope").isEmpty)
        #expect(!store.revealInSidebar("nope"))
        #expect(store.collapsedSections.contains("agent:a"))
    }

    @Test func subagentThreadRevealsParentsSection() {
        defer { self.scratch.remove() }
        let parent = "agent:a:dashboard:1"
        let child = "agent:a:subagent:9"
        let store = self.store([(parent, "Work", nil), (child, nil, parent)], groups: ["Work"])
        store.organization = .agent
        store.sectionCollapse = ["agent:a": true, "agent:a/group:Work": true]
        #expect(store.sidebarAncestors(of: child) == ["agent:a", "agent:a/group:Work"])
        #expect(store.revealInSidebar(child))
        #expect(store.collapsedSections.isDisjoint(with: ["agent:a", "agent:a/group:Work"]))
    }

    @Test func onlyCollapsedAncestorsCount() {
        defer { self.scratch.remove() }
        let key = "agent:a:dashboard:1"
        let store = self.store([(key, "Work", nil)], groups: ["Work"])
        store.organization = .agent
        store.sectionCollapse = ["agent:a/group:Work": true]
        #expect(store.revealInSidebar(key))
        #expect(store.sectionCollapse["agent:a/group:Work"] == false)
    }
}
