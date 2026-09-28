import Foundation
import Testing
@testable import PincerKit

@Suite("Intent label cache")
struct IntentLabelCacheTests {
    static let key = "pincer.intents.labels"

    static func scratch() -> (UserDefaults, String) {
        let name = "pincer-tests-\(UUID())"
        return (UserDefaults(suiteName: name)!, name)
    }

    static func listing(_ prefix: String, _ count: Int) -> [(id: String, label: [String])] {
        (0..<count).map { ("\(prefix)/\($0)", ["\(prefix) \($0)", ""]) }
    }

    @Test func lateSortingGatewayKeepsBothListings() {
        let (defaults, name) = Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        var old: [String: [String]] = [:]
        for index in 0..<1000 { old["\(UUID().uuidString)/agent-\(index)"] = ["Old \(index)", ""] }
        defaults.set(old, forKey: Self.key)
        let gateway = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!.uuidString
        let agents: [(id: String, label: [String])] = (0..<3).map { ("\(gateway)/agent-\($0)", ["Agent \($0)", ""]) }
        let chats: [(id: String, label: [String])] = (0..<3).map { ("\(gateway)/chat-\($0)", ["Chat \($0)", "Agent"]) }
        IntentService.remember(agents, in: defaults)
        IntentService.remember(chats, in: defaults)
        let stored = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        #expect(stored.count == IntentService.labelLimit)
        #expect((agents + chats).allSatisfy { stored[$0.id] != nil })
    }

    @Test func trimsOldestFirst() {
        let (defaults, name) = Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        IntentService.remember(Self.listing("a", 600), in: defaults)
        IntentService.remember(Self.listing("b", 600), in: defaults)
        let stored = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        #expect(stored.count == 1000)
        #expect((0..<600).allSatisfy { stored["b/\($0)"] != nil })
        #expect(stored["a/0"] != nil && stored["a/399"] != nil && stored["a/400"] == nil)
    }

    @Test func oversizedListingKeepsItsFirstEntries() {
        let (defaults, name) = Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        IntentService.remember(Self.listing("x", 1200), in: defaults)
        let stored = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        #expect(stored.count == 1000 && stored["x/0"] != nil && stored["x/999"] != nil && stored["x/1000"] == nil)
    }

    @Test func concurrentRemembersLoseNothing() async {
        let (defaults, name) = Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        nonisolated(unsafe) let shared = defaults
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<20 {
                group.addTask {
                    for batch in 0..<5 {
                        IntentService.remember(Self.listing("t\(task)-\(batch)", 5), in: shared)
                    }
                }
            }
        }
        let stored = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        #expect(stored.count == 20 * 5 * 5)
    }
}
