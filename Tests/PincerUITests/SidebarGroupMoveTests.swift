import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #416: moving a chat into, out of or between groups under an agent re-parents its row right
/// away, even when the flat row order doesn't change, and never shows it twice.
// Serialized: each test boots its own demo gateway, and CI runs the suites in parallel under load.
@Suite(.serialized)
@MainActor
struct SidebarGroupMoveTests {
    private static let utilities = "agent:mochi:dashboard:utilities"
    private static let packing = "agent:mochi:dashboard:packing"

    private func connectedDemo(_ scratch: ScratchDefaults) async throws -> GatewayStore {
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.start()
        let ready = await eventually(timeout: .seconds(60)) {
            gateway.state.isConnected && gateway.sessions[Self.utilities] != nil && !gateway.agents.isEmpty
                && gateway.groupCatalog.contains("Day of move")
        }
        try #require(ready, "demo not ready: state=\(gateway.state) sessions=\(gateway.sessions.count) groups=\(gateway.groupCatalog)")
        gateway.organization = .agent
        return gateway
    }

    private func model(_ gateway: GatewayStore) -> SidebarModel {
        SidebarModel.build(gateway: gateway, search: "", collapsed: [], expandedThreads: [],
                           showSubagentRuns: false, showPreviews: false)
    }

    private func mochi(_ model: SidebarModel) throws -> SidebarModel.Group {
        try #require(model.groups.first { $0.header.section.kind == .agent("mochi") })
    }

    private func flat(_ model: SidebarModel) -> [String] {
        model.groups.flatMap { [$0.header.id] + $0.childIds }
    }

    private func settle(_ gateway: GatewayStore, _ key: String, category: String?) async throws {
        let moved = await eventually(timeout: .seconds(10)) { gateway.sessions[key]?.category == category }
        try #require(moved, "\(key) category=\(gateway.sessions[key]?.category ?? "nil"), wanted \(category ?? "nil")")
    }

    /// The chat's row sits under exactly one header, the expected one.
    private func expectPlaced(_ key: String, under header: String, in model: SidebarModel) throws {
        let id = SidebarModel.entryId(key)
        let placements = model.groups.flatMap(\.placements).filter { $0.id == id }
        #expect(placements == [SidebarModel.Placement(id: id, parent: header)])
        let group = try self.mochi(model)
        #expect(group.allEntries.filter { $0.id == id }.count == 1)
    }

    private func groupHeader(_ name: String) -> String { SidebarModel.headerId("agent:mochi/group:\(name)") }

    private func agentSection(_ gateway: GatewayStore) throws -> SidebarSection {
        try #require(gateway.sections().first { $0.kind == .agent("mochi") })
    }

    @Test func movingIntoANonEmptyGroupWithTheSameFlatOrderRebuilds() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        let before = self.model(gateway)
        try self.expectPlaced(Self.utilities, under: try self.mochi(before).header.id, in: before)

        // Utilities is the first ungrouped chat, right below Day of move's only chat.
        await gateway.moveChat(Self.utilities, toGroup: "Day of move", before: nil)
        try await self.settle(gateway, Self.utilities, category: "Day of move")
        let after = self.model(gateway)

        #expect(self.flat(before) == self.flat(after), "the case #416 hit: same flat order, new parent")
        #expect(SidebarModel.structureChanged(old: before, new: after))
        try self.expectPlaced(Self.utilities, under: self.groupHeader("Day of move"), in: after)
        #expect(try self.mochi(after).entries.isEmpty)
    }

    @Test func movingOutOfAGroupToTheTopOfTheUngroupedChatsRebuilds() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        await gateway.moveChat(Self.utilities, toGroup: "Day of move", before: nil)
        try await self.settle(gateway, Self.utilities, category: "Day of move")
        let before = self.model(gateway)

        let moved = await gateway.moveToGroup(Self.utilities, droppedOn: try self.agentSection(gateway))
        #expect(moved)
        try await self.settle(gateway, Self.utilities, category: nil)
        let after = self.model(gateway)

        #expect(self.flat(before) == self.flat(after), "the last chat of the last group becomes the first ungrouped one")
        #expect(SidebarModel.structureChanged(old: before, new: after))
        try self.expectPlaced(Self.utilities, under: try self.mochi(after).header.id, in: after)
    }

    @Test func movingBetweenGroupsRebuilds() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        let before = self.model(gateway)

        await gateway.moveChat(Self.packing, toGroup: "Day of move", before: nil)
        try await self.settle(gateway, Self.packing, category: "Day of move")
        let after = self.model(gateway)

        #expect(SidebarModel.structureChanged(old: before, new: after))
        try self.expectPlaced(Self.packing, under: self.groupHeader("Day of move"), in: after)
        let groups = try self.mochi(after).subgroups
        #expect(groups.map(\.header.section.title) == ["Preparations", "Day of move"])
        #expect(groups.map(\.entries.count) == [1, 2])
    }

    @Test func movingIntoAnEmptyGroupRebuilds() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        #expect(await gateway.createGroup("Unpacking"))
        let created = await eventually(timeout: .seconds(10)) { gateway.groupNames.contains("Unpacking") }
        try #require(created)
        let before = self.model(gateway)
        #expect(try !self.mochi(before).subgroups.contains { $0.header.section.title == "Unpacking" })

        await gateway.moveChat(Self.utilities, toGroup: "Unpacking", before: nil)
        try await self.settle(gateway, Self.utilities, category: "Unpacking")
        let after = self.model(gateway)

        #expect(SidebarModel.structureChanged(old: before, new: after))
        try self.expectPlaced(Self.utilities, under: self.groupHeader("Unpacking"), in: after)
    }

    @Test func unchangedTreeNeedsNoRebuild() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        let model = self.model(gateway)
        #expect(!SidebarModel.structureChanged(old: model, new: self.model(gateway)))
        let ids = model.groups.flatMap { [$0.header.id] + $0.childIds }
        let placed = model.groups.flatMap { [$0.header.id] + $0.placements.map(\.id) }
        #expect(ids == placed)
        #expect(Set(placed).count == placed.count)
    }
}
