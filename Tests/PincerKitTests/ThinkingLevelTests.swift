import Foundation
import Testing
@testable import PincerKit

// The header's thinking-level picker (#1086): expensive levels, labels, the menu model and the row patch.
struct ThinkingLevelTests {
    static let levels = #"[{"id":"off","label":"Off"},{"id":"low","label":"Low"},{"id":"medium","label":"Medium"},{"id":"high","label":"High"},{"id":"xhigh","label":"Extra High"},{"id":"ultra","label":"Ultra"}]"#

    static func row(_ extra: String = "") -> SessionRow {
        SessionRow(Fixtures.json(#"{"key":"agent:main:main","model":"m","thinkingLevels":\#(levels),"thinkingDefault":"medium"\#(extra)}"#))!
    }

    @Test func expensiveLevels() {
        for id in ["high", "xhigh", "max", "ultra", "ULTRA", " High ", "XHigh"] {
            #expect(ThinkingLevel.isExpensive(id), "\(id) is expensive")
        }
        for id: String? in ["adaptive", "medium", "low", "off", "minimal", "", "  ", nil, "ultra-lite"] {
            #expect(!ThinkingLevel.isExpensive(id), "\(String(describing: id)) isn't expensive")
        }
    }

    @Test func labels() {
        let choices = [SlashCommandChoice(value: "xhigh", label: "Extra High"), SlashCommandChoice(value: "max", label: "Turbo"),
                       SlashCommandChoice(value: "high")]
        #expect(ThinkingLevel.label(for: "max", in: choices) == "Turbo", "the Gateway's label wins")
        #expect(ThinkingLevel.label(for: "MAX", in: choices) == "Turbo", "matched case-insensitively")
        #expect(ThinkingLevel.label(for: "high", in: choices) == "High", "a label equal to the id falls back")
        #expect(ThinkingLevel.label(for: "xhigh", in: nil) == "Extra High")
        #expect(ThinkingLevel.label(for: "ultra", in: nil) == "Ultra")
        #expect(ThinkingLevel.label(for: "medium", in: []) == "Medium")
        #expect(ThinkingLevel.label(for: "adaptive", in: choices) == "Adaptive")
        #expect(ThinkingLevel.label(for: "galaxy", in: nil) == "Galaxy", "an unknown id is capitalized")
        #expect(ThinkingLevel.label(for: "xhigh", in: [SlashCommandChoice(value: "xhigh", label: "XHIGH")]) == "Extra High",
                "a label that only differs in case falls back to the canonical one")
        #expect(ThinkingLevel.label(for: " xhigh ", in: nil) == "Extra High")
    }

    @Test func canonicalLabels() {
        let ids = ["off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max", "ultra"]
        #expect(ids.map { ThinkingLevel.canonicalLabel(for: $0) }
                == ["Off", "Minimal", "Low", "Medium", "High", "Extra High", "Adaptive", "Max", "Ultra"])
        #expect(ThinkingLevel.canonicalLabel(for: "XHigh") == "Extra High")
        #expect(ThinkingLevel.canonicalLabel(for: "galaxy") == nil && ThinkingLevel.canonicalLabel(for: "") == nil)
    }

    @Test func expensiveWarning() {
        #expect(ThinkingLevel.expensiveWarning(for: Self.row(#","thinkingLevel":"ultra""#)) == "Ultra thinking, may be slower and cost more")
        for level in ["high", "max", "XHIGH"] {
            #expect(ThinkingLevel.expensiveWarning(for: Self.row(#","thinkingLevel":"\#(level)""#)) != nil, "\(level) warns")
        }
        #expect(ThinkingLevel.expensiveWarning(for: SessionRow(Fixtures.json(#"{"key":"k","thinkingDefault":"xhigh"}"#))!)?
                    .contains("Extra High") == true, "an inherited expensive default warns too")
        #expect(ThinkingLevel.expensiveWarning(for: Self.row()) == nil)
        #expect(ThinkingLevel.expensiveWarning(for: Self.row(#","thinkingLevel":"adaptive""#)) == nil)
    }

    @Test func rowAccessorsAndPatch() {
        let base = Self.row(#","label":"Keep""#)
        #expect(base.thinkingLevel == nil && base.thinkingDefault == "medium" && base.effectiveThinkingLevel == "medium")
        let set = base.settingThinkingLevel("ultra")
        #expect(set.thinkingLevel == "ultra" && set.effectiveThinkingLevel == "ultra")
        #expect(set.raw["label"] == "Keep" && set.raw["thinkingDefault"] == "medium" && set.key == base.key, "other fields kept")
        let cleared = set.settingThinkingLevel(nil)
        #expect(cleared.thinkingLevel == nil && cleared.raw["thinkingLevel"] == nil && cleared.effectiveThinkingLevel == "medium")
        #expect(cleared.raw["label"] == "Keep" && cleared.thinkingLevelChoices?.count == 6)
        let empty = SessionRow(Fixtures.json(#"{"key":"k","thinkingLevel":""}"#))!
        #expect(empty.thinkingLevel == nil && empty.effectiveThinkingLevel == nil, "an empty level is no level")
    }

    @Test func menuFollowsDefault() {
        let menu = ThinkingLevelMenu(row: Self.row())
        #expect(menu.items.map(\.id) == ["off", "low", "medium", "high", "xhigh", "ultra"], "Gateway order")
        #expect(menu.items.map(\.label) == ["Off", "Low", "Medium", "High", "Extra High", "Ultra"])
        #expect(menu.followsDefault && menu.defaultLabel == "Medium" && menu.reportsLevels)
        #expect(!menu.items.contains { $0.isSelected }, "no item is checked while following the default")
        #expect(menu.items.allSatisfy { $0.isEnabled })
        #expect(menu.items.filter(\.isExpensive).map(\.id) == ["high", "xhigh", "ultra"])
        #expect(menu.currentLevel == "medium" && menu.currentLabel == "Medium" && !menu.currentIsExpensive)
    }

    @Test func menuOverride() {
        let menu = ThinkingLevelMenu(row: Self.row(#","thinkingLevel":"ULTRA""#))
        #expect(!menu.followsDefault && menu.items.count == 6)
        #expect(menu.items.filter(\.isSelected).map(\.id) == ["ultra"], "matched case-insensitively")
        #expect(menu.currentIsExpensive && menu.currentLabel == "Ultra" && menu.defaultLabel == "Medium")

        let unlisted = ThinkingLevelMenu(row: Self.row(#","thinkingLevel":"max""#))
        #expect(unlisted.items.count == 7 && unlisted.items.last?.id == "max")
        #expect(unlisted.items.last?.isSelected == true && unlisted.items.last?.isEnabled == false, "shown checked, can't be picked")
        #expect(unlisted.items.last?.isExpensive == true && unlisted.items.last?.label == "Max")
        #expect(unlisted.items.filter(\.isSelected).count == 1)
    }

    @Test func menuLegacyAndMissingLevels() {
        let legacy = ThinkingLevelMenu(row: SessionRow(Fixtures.json(#"{"key":"k","thinkingOptions":["Low","High"],"thinkingLevel":"high"}"#))!)
        #expect(legacy.reportsLevels && legacy.items.map(\.id) == ["low", "high"] && legacy.items.map(\.label) == ["Low", "High"])
        #expect(legacy.items.filter(\.isSelected).map(\.id) == ["high"] && legacy.currentIsExpensive && legacy.defaultLabel == nil)

        let none = ThinkingLevelMenu(row: SessionRow(Fixtures.json(#"{"key":"k"}"#))!)
        #expect(!none.reportsLevels && none.items.isEmpty && none.followsDefault)
        #expect(none.currentLevel == nil && none.currentLabel == nil && none.defaultLabel == nil && !none.currentIsExpensive)

        let rawLabels = ThinkingLevelMenu(row: SessionRow(Fixtures.json(#"{"key":"k","thinkingLevels":[{"id":"xhigh","label":"xhigh"},{"id":"max"}]}"#))!)
        #expect(rawLabels.items.map(\.label) == ["Extra High", "Max"], "items use Pincer's label when the Gateway's is just the id")

        let onlyOverride = ThinkingLevelMenu(row: SessionRow(Fixtures.json(#"{"key":"k","thinkingLevel":"xhigh"}"#))!)
        #expect(!onlyOverride.reportsLevels && onlyOverride.items.map(\.id) == ["xhigh"] && onlyOverride.items.first?.isEnabled == false)
        #expect(onlyOverride.currentLabel == "Extra High" && onlyOverride.currentIsExpensive)
    }
}

#if DEBUG
// GatewayStore.setThinkingLevel against the built-in demo: optimistic, null resets, rollback, last pick wins.
@MainActor @Suite(.timeLimit(.minutes(2)))
struct ThinkingLevelStoreTests {
    actor Delivery {
        var entered = false, released = false
        var waiter: CheckedContinuation<Void, Never>?
        func hold(_ method: String) async {
            guard method == "sessions.patch", !released else { return }
            entered = true
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiter = continuation }
            }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    static let main = "agent:main:main", papers = "agent:research:dashboard:papers"

    func connected() async throws -> (GatewayStore, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        gateway.start(); gateway.reconnectIfNeeded()
        let ready = ContinuousClock.now.advanced(by: .seconds(25))
        while !gateway.state.isConnected || !gateway.bootstrapped {
            try Task.checkCancellation(); try #require(ContinuousClock.now < ready)
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gateway.sessions[Self.main] != nil && gateway.sessions[Self.papers] != nil)
        return (gateway, scratch)
    }

    @Test func optimisticBeforeTheReplyThenReset() async throws {
        let (gateway, scratch) = try await connected()
        defer { gateway.stop(); scratch.remove() }
        #expect(gateway.sessions[Self.main]?.thinkingLevel == nil && gateway.sessions[Self.main]?.thinkingDefault == "medium")
        let delivery = Delivery()
        await gateway.connection.setDemoResponseDelivery { await delivery.hold($0) }
        let pick = Task { await gateway.setThinkingLevel(Self.main, to: "low") }
        let admission = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await delivery.entered) {
            if ContinuousClock.now >= admission { await delivery.release(); _ = await pick.value; Issue.record("patch never sent"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gateway.sessions[Self.main]?.thinkingLevel == "low", "the row updates before the Gateway answers")
        await delivery.release()
        await pick.value
        await gateway.connection.setDemoResponseDelivery(nil)
        #expect(gateway.sessions[Self.main]?.thinkingLevel == "low" && gateway.lastError == nil)

        await gateway.setThinkingLevel(Self.main, to: nil)
        #expect(gateway.sessions[Self.main]?.thinkingLevel == nil && gateway.sessions[Self.main]?.effectiveThinkingLevel == "medium")
        await gateway.refreshSessions()
        #expect(gateway.sessions[Self.main]?.thinkingLevel == nil, "null reached the Gateway and cleared its override")
        #expect(gateway.lastError == nil)
    }

    @Test func rejectionRollsBack() async throws {
        let (gateway, scratch) = try await connected()
        defer { gateway.stop(); scratch.remove() }
        #expect(gateway.sessions[Self.papers]?.thinkingLevel == "ultra")
        await gateway.setThinkingLevel(Self.papers, to: "galaxy-brain")
        #expect(gateway.sessions[Self.papers]?.thinkingLevel == "ultra", "the rejected pick rolls back")
        #expect(gateway.lastError?.isEmpty == false)
    }

    @Test func staleFailureKeepsTheNewerPick() async throws {
        let (gateway, scratch) = try await connected()
        defer { gateway.stop(); scratch.remove() }
        let stale = Task { await gateway.setThinkingLevel(Self.main, to: "galaxy-brain") }
        // The main actor is FIFO: once the stale pick has applied, its failure can only resume after this job.
        while gateway.thinkingLevelRequests[Self.main] != 1 { await Task.yield() }
        try #require(gateway.sessions[Self.main]?.thinkingLevel == "galaxy-brain")
        await gateway.setThinkingLevel(Self.main, to: "high")
        await stale.value
        #expect(gateway.lastError?.isEmpty == false, "the stale pick still reports its error")
        #expect(gateway.sessions[Self.main]?.thinkingLevel == "high", "the stale failure doesn't undo the newer pick")
        await gateway.refreshSessions()
        #expect(gateway.sessions[Self.main]?.thinkingLevel == "high")
    }

    @Test func unknownKeyIsANoOp() async throws {
        let (gateway, scratch) = try await connected()
        defer { gateway.stop(); scratch.remove() }
        let before = gateway.sessions.count
        await gateway.setThinkingLevel("agent:main:dashboard:nope", to: "high")
        #expect(gateway.sessions["agent:main:dashboard:nope"] == nil && gateway.sessions.count == before)
        #expect(gateway.thinkingLevelRequests.isEmpty && gateway.lastError == nil)
    }
}
#endif
