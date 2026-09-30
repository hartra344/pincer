import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// The platform-free sidebar rules shared by the AppKit and UIKit coordinators.
@MainActor
struct SidebarControllerTests {
    private func row(_ key: String, agent: String = "mochi") -> SessionRow {
        SessionRow(.object(["key": .string(key), "agentId": .string(agent)]))!
    }

    private func entry(_ key: String, agent: String = "mochi", thread: Bool = false) -> SidebarModel.Entry {
        SidebarModel.Entry(id: SidebarModel.entryId(key), row: self.row(key, agent: agent), icon: nil, color: nil,
                           isThread: thread, subagentCount: 0, runningSubagents: 0, hiddenUnreadThreads: 0,
                           threadsExpanded: false, showSubagentRuns: false, preview: nil, working: nil,
                           avatar: nil, avatarStyle: nil)
    }

    private func section(_ id: String, _ kind: SidebarSection.Kind) -> SidebarSection {
        SidebarSection(id: id, title: id, emoji: nil, channels: [], kind: kind)
    }

    private func header(_ id: String, _ kind: SidebarSection.Kind, collapsed: Bool = false) -> SidebarModel.Header {
        SidebarModel.Header(id: SidebarModel.headerId(id), section: self.section(id, kind), isCollapsed: collapsed, newChatAgent: nil)
    }

    private func group(_ header: SidebarModel.Header, leading: [SidebarModel.Entry] = [], entries: [SidebarModel.Entry] = [],
                       subgroups: [SidebarModel.Group] = []) -> SidebarModel.Group
    {
        SidebarModel.Group(header: header, entries: entries, leadingEntries: leading, subgroups: subgroups)
    }

    private func nestedModel() -> SidebarModel {
        let nested = self.group(self.header("mochi/utilities", .agentGroup(agent: "mochi", group: "utilities")),
                                entries: [self.entry("agent:mochi:dashboard:u1")])
        let agent = self.group(self.header("mochi", .agent("mochi")), leading: [self.entry("agent:mochi:main")],
                               entries: [self.entry("agent:mochi:dashboard:tail")], subgroups: [nested])
        let plain = self.group(self.header("other", .other), entries: [self.entry("agent:main:dashboard:x")])
        return SidebarModel(groups: [agent, plain])
    }

    // MARK: Index

    @Test func indexCoversNestedSubgroupsAndLeadingEntries() {
        let controller = SidebarController()
        let model = self.nestedModel()
        let update = controller.accept(model: model)
        #expect(update?.isInitial == true)
        #expect(Set(controller.headers.keys) == Set(model.groups.flatMap(\.allHeaders).map(\.id)))
        #expect(Set(controller.entries.keys) == Set(model.groups.flatMap(\.allEntries).map(\.id)))
        #expect(controller.headers.count == 3)
        #expect(controller.entries[SidebarModel.entryId("agent:mochi:main")] != nil)
        #expect(controller.entries[SidebarModel.entryId("agent:mochi:dashboard:u1")] != nil)
    }

    @Test func acceptReportsChangesOnly() {
        let controller = SidebarController()
        let model = self.nestedModel()
        #expect(controller.accept(model: model) != nil)
        // Not loaded until the platform says so.
        #expect(controller.accept(model: model)?.isInitial == true)
        controller.markLoaded()
        #expect(controller.accept(model: model) == nil)
        let update = controller.accept(model: SidebarModel())
        #expect(update?.old == model)
        #expect(update?.isInitial == false)
        #expect(controller.headers.isEmpty && controller.entries.isEmpty)
    }

    // MARK: Programmatic guard, selection, expansion

    @Test func programmaticNests() {
        let controller = SidebarController()
        #expect(!controller.isProgrammatic)
        controller.programmatic {
            #expect(controller.isProgrammatic)
            controller.programmatic { #expect(controller.isProgrammatic) }
            #expect(controller.isProgrammatic)
        }
        #expect(!controller.isProgrammatic)
    }

    @Test func selectionTarget() {
        let controller = SidebarController()
        #expect(controller.selectionTarget() == nil)
        controller.selectedKey = "agent:mochi:main"
        #expect(controller.selectionTarget() == SidebarModel.entryId("agent:mochi:main"))
        #expect(controller.selectionTarget(hidden: true) == nil)
    }

    @Test func userSelectionIgnoredWhileProgrammatic() {
        let controller = SidebarController()
        let entry = self.entry("agent:mochi:main")
        controller.programmatic { #expect(controller.userSelected(entry) == nil) }
        #expect(controller.selectedKey == nil)
        #expect(controller.userSelected(nil) == nil)
        #expect(controller.userSelected(entry) == "agent:mochi:main")
        #expect(controller.selectedKey == "agent:mochi:main")
    }

    @Test func expansionDecision() {
        let controller = SidebarController()
        _ = controller.accept(model: self.nestedModel())
        let id = SidebarModel.headerId("mochi/utilities")
        #expect(controller.sectionToggled(headerId: id) == "mochi/utilities")
        #expect(controller.sectionToggled(headerId: "missing") == nil)
        controller.programmatic { #expect(controller.sectionToggled(headerId: id) == nil) }
    }

    // MARK: Drag

    @Test func dragPayloads() {
        let controller = SidebarController()
        let thread = self.entry("agent:mochi:dashboard:t", thread: true)
        let subagent = self.entry("agent:mochi:subagent:s")
        let chat = self.entry("agent:mochi:dashboard:c")
        let groupHeader = self.header("Trips", .group("Trips"))
        let model = SidebarModel(groups: [
            self.group(groupHeader, entries: [chat, thread, subagent]),
            self.group(self.header("mochi", .agent("mochi"))),
            self.group(self.header("mochi/utilities", .agentGroup(agent: "mochi", group: "utilities"))),
        ])
        _ = controller.accept(model: model)
        #expect(controller.dragPayload(forId: groupHeader.id) == .group("Trips"))
        #expect(controller.dragPayload(forId: SidebarModel.headerId("mochi")) == nil)
        #expect(controller.dragPayload(forId: SidebarModel.headerId("mochi/utilities")) == nil)
        #expect(controller.dragPayload(forId: chat.id) == .chat("agent:mochi:dashboard:c"))
        #expect(controller.dragPayload(forId: thread.id) == nil)
        #expect(controller.dragPayload(forId: subagent.id) == nil)
        #expect(controller.dragPayload(forId: "missing") == nil)
        #expect(SidebarDragPayload.chat("k").typeIdentifier == SidebarDrag.typeIdentifier)
        #expect(SidebarDragPayload.group("g").typeIdentifier == SidebarDrag.groupTypeIdentifier)
        #expect(SidebarDragPayload.group("g").value == "g")
    }

    // MARK: Drop rules

    @Test func groupAcceptsChatsOnlyWhenOpenAndForItsAgent() {
        let mochi = self.row("agent:mochi:dashboard:a", agent: "mochi")
        let open = self.header("Trips", .group("Trips"))
        #expect(SidebarController.groupAccepting(mochi, in: open) == "Trips")
        #expect(SidebarController.groupAccepting(mochi, in: self.header("Trips", .group("Trips"), collapsed: true)) == nil)
        #expect(SidebarController.groupAccepting(mochi, in: self.header("mochi", .agent("mochi"))) == nil)
        let nested = self.header("m/u", .agentGroup(agent: "mochi", group: "u"))
        #expect(SidebarController.groupAccepting(mochi, in: nested) == "u")
        let other = self.row("agent:main:dashboard:b", agent: "main")
        #expect(SidebarController.groupAccepting(other, in: nested) == nil)
        #expect(SidebarController.groupAccepting(other, in: open) == "Trips")
    }

    @Test func beforeKeySkipsThreadsAndTheMovedChat() {
        let entries = [self.entry("a"), self.entry("b", thread: true), self.entry("c"), self.entry("d")]
        #expect(SidebarModel.chat(atOrAfter: 0, in: entries, excluding: "z") == "a")
        #expect(SidebarModel.chat(atOrAfter: 0, in: entries, excluding: "a") == "c")
        #expect(SidebarModel.chat(atOrAfter: 1, in: entries, excluding: "z") == "c")
        #expect(SidebarModel.chat(atOrAfter: 4, in: entries, excluding: "z") == nil)
    }

    @Test func groupReorderAmongRoots() {
        let roots = [self.header("mochi", .agent("mochi")), self.header("A", .group("A")),
                     self.header("B", .group("B")), self.header("C", .group("C")), self.header("o", .other)]
        // Dropped ahead of B, moving A down: after B's slot, so before C.
        let down = SidebarController.groupReorder("A", among: roots) { source in source < 2 ? 3 : 2 }
        #expect(down?.rootIndex == 3)
        #expect(down?.drop == .group("A", before: "C"))
        // Above the first group clamps to it; below the last clamps to the end.
        #expect(SidebarController.groupReorder("B", among: roots) { _ in 0 }?.drop == .group("B", before: "A"))
        #expect(SidebarController.groupReorder("A", among: roots) { _ in 5 }?.drop == .group("A", before: nil))
        #expect(SidebarController.groupReorder("A", among: roots) { _ in 5 }?.rootIndex == 4)
        #expect(SidebarController.groupReorder("missing", among: roots) { _ in 1 } == nil)
        #expect(SidebarController.groupReorder("A", among: roots) { _ in nil } == nil)
        #expect(SidebarController.groupReorder("A", among: [roots[0]]) { _ in 0 } == nil)
    }

    @Test func groupReorderByNames() {
        let names = ["A", "B", "C"]
        // On a group after the source: one further, since the source leaves its place.
        #expect(SidebarController.groupReorder("A", names: names, groupsBefore: 1, onGroup: true) == .group("A", before: "C"))
        // On a group before the source: in front of it.
        #expect(SidebarController.groupReorder("C", names: names, groupsBefore: 1, onGroup: true) == .group("C", before: "B"))
        // A plain section takes the next group after it, or the end.
        #expect(SidebarController.groupReorder("A", names: names, groupsBefore: 0, onGroup: false) == .group("A", before: "A"))
        #expect(SidebarController.groupReorder("A", names: names, groupsBefore: 3, onGroup: false) == .group("A", before: nil))
        #expect(SidebarController.groupReorder("nope", names: names, groupsBefore: 0, onGroup: false) == nil)
        #expect(SidebarDrop.group("A", before: nil).isInsertion)
        #expect(!SidebarDrop.chatOnSection("k", self.section("s", .other)).isInsertion)
    }
}
