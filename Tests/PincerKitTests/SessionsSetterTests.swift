import Foundation
import Observation
import Testing
@testable import PincerKit

@MainActor
@Suite("Sessions setter")
struct SessionsSetterTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)

    func rows(_ entries: [(String, Int, Bool)] = [("a", 100, false), ("b", 200, false), ("c", 300, false)]) -> JSONValue {
        let items = entries.map { #"{"key":"agent:main:dashboard:\#($0.0)","label":"\#($0.0)","updatedAt":\#($0.1),"archived":\#($0.2)}"# }
        return Fixtures.json(#"{"sessions":[\#(items.joined(separator: ","))]}"#)
    }

    func store() -> GatewayStore {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        store.applySnapshot(self.rows())
        return store
    }

    func order(_ store: GatewayStore) -> [String] { store.sortedRows.map { $0.key.split(separator: ":").last.map(String.init) ?? "" } }

    @Test func identicalWriteIsSilentAndKeepsTrees() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.subagentTrees["probe"] = SubagentTree(rootKey: "x")
        let fired = Fires()
        withObservationTracking { _ = store.sessions } onChange: { fired.bump() }
        store.applySnapshot(self.rows())
        #expect(fired.count == 0)
        #expect(store.subagentTrees["probe"] != nil)
    }

    @Test func realChangeFiresOnce() {
        defer { self.scratch.remove() }
        let store = self.store()
        let fired = Fires()
        withObservationTracking { _ = store.sessions } onChange: { fired.bump() }
        store.applySnapshot(self.rows([("a", 100, false), ("b", 250, false), ("c", 300, false)]))
        #expect(fired.count == 1)
        #expect(store.subagentTrees.isEmpty)
    }

    @Test func sortedRowsTracksChanges() {
        defer { self.scratch.remove() }
        let store = self.store()
        #expect(self.order(store) == ["c", "b", "a"])
        store.applySnapshot(self.rows([("a", 400, false), ("b", 200, false), ("c", 300, false)]))
        #expect(self.order(store) == ["a", "c", "b"])
        store.applySnapshot(self.rows([("a", 400, false), ("b", 200, false), ("c", 300, false), ("d", 500, false)]))
        #expect(self.order(store) == ["d", "a", "c", "b"])
        store.applySnapshot(self.rows([("a", 400, true), ("b", 200, false), ("c", 300, false), ("d", 500, false)]))
        #expect(self.order(store) == ["d", "c", "b"])
        store.showArchived = true
        #expect(self.order(store).contains("a"))
    }
}
