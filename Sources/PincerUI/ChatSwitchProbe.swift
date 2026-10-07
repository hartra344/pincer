#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// `PincerMacDev --chat-switch-probe`: opens the demo, switches back and forth between the long
/// *Home-lab migration* chat and other demo chats, and times each switch from `selectedKey` to the
/// new chat's rows being laid out and visible in the window's transcript (#563). Fails if a switch
/// between warm chats takes longer than the budget. Run it with `PINCER_DEV_NAMESPACE` and
/// `PINCER_KEYCHAIN=memory` so it leaves your own gateways alone.
@MainActor public enum ChatSwitchProbe {
    /// With `url`, runs against that Gateway (token `token`) instead of the demo, e.g. the mock
    /// Gateway with `MOCK_DELAY_METHODS=chat.history=1500` to show whether a switch waits on the network.
    public static func run(url: String? = nil, token: String = "dev-token", rounds: Int = 6, maxChats: Int = Int(ProcessInfo.processInfo.environment["PINCER_SWITCH_CHATS"] ?? "") ?? 2, budget: Double? = nil) async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        // `PINCER_SWITCH_BUDGET_MS`: per-chat median ceiling. `PINCER_SWITCH_OVERALL_MS`: optional
        // ceiling on the median of every timed switch, the steadiest figure on a noisy machine (#571).
        // `PINCER_SWITCH_STALL_MS`: optional ceiling on the longest stall.
        let budget = budget ?? (env["PINCER_SWITCH_BUDGET_MS"].flatMap(Double.init) ?? 150) / 1000
        let overallBudget = env["PINCER_SWITCH_OVERALL_MS"].flatMap(Double.init).map { $0 / 1000 }
        let stallBudget = env["PINCER_SWITCH_STALL_MS"].flatMap(Double.init).map { $0 / 1000 }
        let app = AppModel.shared
        if ProcessInfo.processInfo.environment["PINCER_SWITCH_MENU_BAR"] == "1" { MenuBarSettings().setEnabled(true) }
        var added: UUID?
        if let url {
            let profile = GatewayProfile(name: "Switch probe", url: url, authMode: .token)
            added = app.add(profile, secret: token).id
        } else if !app.gateways.contains(where: { $0.profile.isDemo }) {
            app.openDemo()
            added = app.gateways.first { $0.profile.isDemo }?.id
        } else {
            app.openDemo()
        }
        defer { if let added { app.remove(added) } }

        var window: NSWindow?
        var gateway: GatewayStore?
        for _ in 0..<150 {
            gateway = app.selectedGateway
            window = NSApp.windows.first { $0.toolbar != nil && $0.isVisible }
            if let gateway, gateway.sessions.count >= 3, window != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let gateway, let window, gateway.sessions.count >= 3 else {
            print("Chat switch probe: FAIL, the demo didn't show a window with its chats")
            return 2
        }
        let rows = gateway.sessions.values.sorted { $0.key < $1.key }
        guard let long = rows.first(where: {
            $0.title.localizedCaseInsensitiveContains("Home-lab") || $0.key.hasSuffix(":long-chat")
        }) else {
            print("Chat switch probe: FAIL, no long chat (Home-lab migration or the mock's long-chat)")
            return 2
        }
        let others = rows.filter { $0.key != long.key && !$0.isSubagent && !$0.isPlaceholder && !$0.isArchived }.prefix(maxChats).map(\.key)
        let keys = [long.key] + others

        // Warm every chat once, untimed.
        for key in keys {
            _ = await self.switchTo(key, gateway: gateway, window: window)
        }
        var times: [String: [Double]] = [:]
        var hangs: [Double] = []
        for round in 0..<max(rounds, others.count * 2) {
            for key in [long.key, others[round % others.count]] {
                let (seconds, hang) = await self.switchTo(key, gateway: gateway, window: window)
                times[key, default: []].append(seconds)
                hangs.append(hang)
            }
        }
        var failures = 0
        for key in keys {
            guard let values = times[key], !values.isEmpty else { continue }
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            let title = gateway.sessions[key]?.title ?? key
            print(String(format: "Chat switch probe: %@: median %.0f ms, max %.0f ms over %d switches",
                         title, median * 1000, (sorted.last ?? 0) * 1000, values.count))
            if median > budget { failures += 1 }
        }
        let all = times.values.flatMap { $0 }.sorted()
        let longestStall = hangs.max() ?? 0
        let overall = all.isEmpty ? 0 : all[all.count / 2]
        let p90 = all.isEmpty ? 0 : all[min(all.count - 1, all.count * 9 / 10)]
        print(String(format: "Chat switch probe: overall median %.0f ms, p90 %.0f ms, max %.0f ms over %d switches",
                     overall * 1000, p90 * 1000, (all.last ?? 0) * 1000, all.count))
        if let overallBudget, overall > overallBudget {
            failures += 1
            print(String(format: "Chat switch probe: overall median over the %.0f ms budget", overallBudget * 1000))
        }
        print(String(format: "Chat switch probe: longest main-thread stall %.0f ms", longestStall * 1000))
        if let stallBudget, longestStall > stallBudget {
            failures += 1
            print(String(format: "Chat switch probe: stall over the %.0f ms budget", stallBudget * 1000))
        }
        print(failures == 0
            ? String(format: "Chat switch probe: OK, warm switches under %.0f ms", budget * 1000)
            : String(format: "Chat switch probe: FAIL, %d checks over budget (median %.0f ms)", failures, budget * 1000))
        return failures == 0 ? 0 : 1
    }

    /// Selects `key` and waits (up to 10 s) until its transcript is on screen. Returns the elapsed
    /// time and the longest gap between two polls (a main-thread stall).
    private static func switchTo(_ key: String, gateway: GatewayStore, window: NSWindow) async -> (Double, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        var last = start, hang = 0.0
        // The user's path: select the row in the sidebar, which calls the sidebar's select action.
        if let outline = self.outline(in: window), let row = self.sidebarRow(key, in: outline) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            gateway.selectedKey = key
        }
        while ProcessInfo.processInfo.systemUptime - start < 10 {
            try? await Task.sleep(for: .milliseconds(2))
            let now = ProcessInfo.processInfo.systemUptime
            hang = max(hang, now - last)
            last = now
            if self.isShown(key, in: window) { break }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        // Let trailing work settle before the next switch.
        try? await Task.sleep(for: .milliseconds(300))
        return (elapsed, hang)
    }

    /// The transcript table the last check found. While it's still on screen only it is checked, so
    /// the probe doesn't walk the whole view tree on the main thread every poll and time itself (#571).
    private static weak var transcriptTable: NSTableView?

    private static func isShown(_ key: String, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let candidates: [NSTableView]
        if let cached = self.transcriptTable, cached.window === window, !cached.isHiddenOrHasHiddenAncestor {
            candidates = [cached]
        } else {
            candidates = self.tables(in: content).filter { $0.delegate is TranscriptList.Coordinator }
            self.transcriptTable = candidates.first
        }
        for table in candidates {
            guard let coordinator = table.delegate as? TranscriptList.Coordinator,
                  coordinator.controller.context.sessionKey == key, table.numberOfRows > 0 else { continue }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0,
                  table.view(atColumn: 0, row: visible.location + visible.length - 1, makeIfNecessary: false) != nil
            else { continue }
            return true
        }
        return false
    }

    private static func outline(in window: NSWindow) -> NSOutlineView? {
        guard let content = window.contentView else { return nil }
        return self.tables(in: content).lazy.compactMap { $0 as? NSOutlineView }.first
    }

    private static func sidebarRow(_ key: String, in outline: NSOutlineView) -> Int? {
        let id = SidebarModel.entryId(key)
        return (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarList.Node)?.id == id }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor { found.append(table) }
        for sub in view.subviews { found += self.tables(in: sub) }
        return found
    }
}
#endif
