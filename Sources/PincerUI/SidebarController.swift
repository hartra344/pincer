import PincerKit

/// Where a sidebar drop lands, once a platform has mapped its own position to a group or chat.
enum SidebarDrop: Equatable {
    /// A group moved in front of another group, or to the end.
    case group(String, before: String?)
    /// A chat placed in a group, in front of `before` (the end when nil).
    case chatInGroup(String, group: String, before: String?)
    /// A chat dropped on a section as a whole.
    case chatOnSection(String, SidebarSection)

    /// Whether the drop is a position between rows, rather than on a section.
    var isInsertion: Bool {
        if case .chatOnSection = self { return false }
        return true
    }
}

extension SidebarDragPayload {
    /// The type identifier and string an item of this drag carries.
    var typeIdentifier: String {
        switch self {
        case .chat: SidebarDrag.typeIdentifier
        case .group: SidebarDrag.groupTypeIdentifier
        }
    }

    var value: String {
        switch self {
        case let .chat(key), let .group(key): key
        }
    }
}

/// The platform-free half of the sidebar lists: id indexes, model bookkeeping, selection and
/// expansion rules, and what may be dragged and dropped where. The AppKit and UIKit coordinators
/// map their own rows and positions onto it.
@MainActor
final class SidebarController {
    private(set) var model = SidebarModel()
    private(set) var hasLoaded = false
    private(set) var headers: [String: SidebarModel.Header] = [:]
    private(set) var entries: [String: SidebarModel.Entry] = [:]
    var selectedKey: String?
    private(set) var isProgrammatic = false

    struct Update {
        let old: SidebarModel
        /// The list hasn't shown a model yet, so it has to load rather than refresh.
        let isInitial: Bool
    }

    /// Takes the model to show. Nil when the list already shows it; otherwise the index is
    /// rebuilt and the previous model returned.
    func accept(model: SidebarModel) -> Update? {
        guard model != self.model || !self.hasLoaded else { return nil }
        let update = Update(old: self.model, isInitial: !self.hasLoaded)
        self.model = model
        self.rebuildIndex()
        return update
    }

    func markLoaded() { self.hasLoaded = true }

    private func rebuildIndex() {
        self.headers = [:]
        self.entries = [:]
        for group in self.model.groups {
            for header in group.allHeaders { self.headers[header.id] = header }
            for entry in group.allEntries { self.entries[entry.id] = entry }
        }
    }

    // MARK: Programmatic changes

    /// Runs a change the list makes itself, whose selection and expansion callbacks are ignored.
    func programmatic(_ body: () -> Void) {
        let was = self.isProgrammatic
        self.isProgrammatic = true
        body()
        self.isProgrammatic = was
    }

    // MARK: Selection and expansion

    /// The row id the selection belongs on; nil when nothing is selected or the list hides it.
    func selectionTarget(hidden: Bool = false) -> String? {
        hidden ? nil : self.selectedKey.map(SidebarModel.entryId)
    }

    /// The entry the user picked. Nil while the list is changing itself.
    func userSelected(_ entry: SidebarModel.Entry?) -> String? {
        guard !self.isProgrammatic, let entry else { return nil }
        self.selectedKey = entry.row.key
        return entry.row.key
    }

    /// The section to collapse or expand after the user toggled a header; nil to ignore.
    func sectionToggled(headerId id: String) -> String? {
        guard !self.isProgrammatic, let header = self.headers[id] else { return nil }
        return header.section.id
    }

    // MARK: Drag

    /// What dragging the row starts: a group header moves the group, a plain chat moves the chat.
    func dragPayload(forId id: String) -> SidebarDragPayload? {
        if let header = self.headers[id] {
            guard case let .group(name) = header.section.kind else { return nil }
            return .group(name)
        }
        guard let entry = self.entries[id], !entry.isThread, !entry.row.isSubagent else { return nil }
        return .chat(entry.row.key)
    }

    // MARK: Drop rules

    /// The group a chat placed inside this header goes into: an open group that takes the chat's agent.
    static func groupAccepting(_ row: SessionRow, in header: SidebarModel.Header) -> String? {
        guard let group = header.section.groupName, !header.isCollapsed,
              header.section.agentId == nil || header.section.agentId == row.agentId
        else { return nil }
        return group
    }

    /// A chat dropped on a section as a whole, when the section can take it.
    static func dropOnSection(_ key: String, _ section: SidebarSection, gateway: GatewayStore) -> SidebarDrop? {
        gateway.groupDropValue(for: key, onto: section) == nil ? nil : .chatOnSection(key, section)
    }

    /// Reordering a group among the top-level headers. `rootIndex` maps the group's current index
    /// to where the drop landed; the result is clamped to the groups' own span.
    static func groupReorder(_ name: String, among roots: [SidebarModel.Header],
                             rootIndex: (_ source: Int) -> Int?) -> (rootIndex: Int, drop: SidebarDrop)?
    {
        func groupName(_ header: SidebarModel.Header) -> String? {
            if case let .group(group) = header.section.kind { return group }
            return nil
        }
        let groupIndices = roots.indices.filter { groupName(roots[$0]) != nil }
        guard let first = groupIndices.first, let last = groupIndices.last,
              let source = roots.firstIndex(where: { groupName($0) == name }),
              var index = rootIndex(source)
        else { return nil }
        index = min(max(index, first), last + 1)
        let before = roots.indices.contains(index) ? groupName(roots[index]) : nil
        return (index, .group(name, before: before))
    }

    /// Reordering a group by group names. `groupsBefore` counts the groups above the drop's
    /// section, which is itself a group when `onGroup`.
    static func groupReorder(_ name: String, names: [String], groupsBefore: Int, onGroup: Bool) -> SidebarDrop? {
        guard let source = names.firstIndex(of: name) else { return nil }
        var target = groupsBefore
        if onGroup, groupsBefore > source { target += 1 }
        return .group(name, before: names.indices.contains(target) ? names[target] : nil)
    }

    static func perform(_ drop: SidebarDrop, gateway: GatewayStore) {
        switch drop {
        case let .group(name, before):
            Task { await gateway.moveGroup(name, before: before) }
        case let .chatInGroup(key, group, before):
            Task { await gateway.moveChat(key, toGroup: group, before: before) }
        case let .chatOnSection(key, section):
            Task { await gateway.moveToGroup(key, droppedOn: section) }
        }
    }
}
