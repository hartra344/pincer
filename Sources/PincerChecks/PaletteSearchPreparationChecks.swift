#if DEBUG
import Foundation
@testable import PincerKit

@MainActor func runPaletteSearchPreparationChecks() async {
    let items = [PaletteItem(id: "late", title: "Plans Café", symbol: "x", section: .chats, action: .command("late")),
                 PaletteItem(id: "exact", title: "Café", symbol: "x", section: .chats, action: .command("exact"))]
    let probe = PaletteSearchProbe()
    let results = await PaletteSearchDiagnostics.$probe.withValue(probe) {
        await PaletteSearchPreparation.prepare(items, query: "cafe", page: .root, gatewaySelected: false)
    }
    check(results.map(\.id) == ["exact", "late"], "actual palette keeps exact case/diacritic ranking and full tail match")
    check(probe.counts.main == [0, 0, 0] && probe.counts.worker.allSatisfy { $0 > 0 }, "actual palette normalization/scoring/sorting run off Main")
    let blank = await PaletteSearchPreparation.prepare(items, query: "", page: .models, gatewaySelected: false)
    check(blank.map(\.id) == ["late", "exact"], "blank model query retains original order")
    let messages = await PaletteSearchPreparation.prepare(items, query: "unmatched", page: .messages, gatewaySelected: false)
    check(messages.map(\.id) == ["late", "exact"], "already-prepared message page bypasses fuzzy ranking")
}

@MainActor func runDemoPaletteSearchPreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("palette inventory Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped && !gateway.sessions.isEmpty }
    check(ready, "actual Demo session inventory is ready and nonempty"); guard ready else { return }
    let items = CommandPalette.chatItems(gateways: [gateway], selectedGatewayId: gateway.id, recent: [])
    let expected = "chat:\(gateway.id.uuidString):agent:main:dashboard:rate-limiter"
    guard items.contains(where: { $0.id == expected && $0.title == "Rate limiter design" }) else {
        check(false, "actual Demo palette includes the known Rate limiter session"); return
    }
    let probe = PaletteSearchProbe()
    let found = await PaletteSearchDiagnostics.$probe.withValue(probe) {
        await PaletteSearchPreparation.prepare(items, query: "rate limiter design", page: .root, gatewaySelected: false)
    }
    check(found.map(\.id) == [expected], "actual complete Demo inventory yields exact known matching chat")
    check(probe.counts.main == [0, 0, 0] && probe.counts.worker.allSatisfy { $0 > 0 }, "real Demo palette preparation executes off Main")
}
#endif
