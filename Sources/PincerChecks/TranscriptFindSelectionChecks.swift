import Foundation
@testable import PincerKit

@MainActor
private func checkFindSelection(_ matches: [TranscriptSearch.Match], rows: [String: Int]) {
    check(matches.count >= 3, "Find selection has three actual matches")
    guard matches.count >= 3 else { return }
    for forward in [true, false] {
        var state = TranscriptFindSelection()
        state.select(1)
        let capture = state.capture(matches: matches, rowIndex: rows)
        let selected = TranscriptSearch.step(from: state.current, count: matches.count, forward: forward)!
        state.select(selected)
        check(state.current == selected && selected != 1, "actual navigation changes selection before completion")
        state.complete(capture, matches: matches, rowIndex: rows)
        check(state.current == selected, "refresh completion retains newer navigation")
    }
    var state = TranscriptFindSelection()
    state.select(1)
    let capture = state.capture(matches: matches, rowIndex: rows)
    check(state.complete(capture, matches: matches, rowIndex: rows) == 1, "ordinary refresh retains selection")
    let preferred = state.capture(matches: matches, rowIndex: rows, preferred: matches[2])
    check(state.complete(preferred, matches: matches, rowIndex: rows) == 2, "preferred initial match remains selected")
}

@MainActor
func runTranscriptFindSelectionChecks() async {
    let result = await Task.detached {
        let entries: [TranscriptEntry] = (0..<3).map {
            .user(ChatItem(id: "find-\($0)", role: .user, blocks: [.text("ordinary needle message")], timestamp: Date(timeIntervalSince1970: 1)))
        }
        return (TranscriptSearch.matches("needle", in: entries, options: .init()),
                Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }.value
    checkFindSelection(result.0, rows: result.1)
}

@MainActor
func runDemoTranscriptFindSelectionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("Find Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "Find uses a genuine connected Demo")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:dashboard:trip")
    await chat.load()
    let loaded = await chat.loadFullHistory()
    check(loaded && !chat.items.isEmpty && !chat.hasOlderItems, "actual seeded trip history is complete and nonempty")
    guard loaded && !chat.items.isEmpty && !chat.hasOlderItems else { return }
    let entries = chat.entries
    let result = await Task.detached {
        (TranscriptSearch.matches("day", in: entries, options: .init()),
         Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }.value
    check(result.0.count >= 3 && result.0.allSatisfy { result.1[$0.entryId] != nil },
          "real Demo day text supplies actual transcript matches")
    checkFindSelection(result.0, rows: result.1)
}
