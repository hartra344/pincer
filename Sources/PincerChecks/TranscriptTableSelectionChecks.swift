import Foundation
@testable import PincerKit
#if DEBUG && os(macOS)
@testable import PincerUI

// #967: a Markdown table's selectable text is its rendered cells, tabs between cells and newlines between rows.

@MainActor
private func tableRenderer(_ gateway: GatewayStore, key: String) -> TranscriptRenderer {
    let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                    agent: AgentSummary(id: "main", name: "Claw"), sessionKey: key,
                                    previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
    return TranscriptRenderer(context: context)
}

@MainActor
private func renderedTables(_ markdown: String, gateway: GatewayStore) -> [TranscriptPart.Table] {
    var turn = AssistantTurn(id: "table-checks", timestamp: Date(timeIntervalSince1970: 1))
    turn.text = [markdown]
    let layout = tableRenderer(gateway, key: "agent:main:main").layout(for: .entry(.assistant(turn)), width: 700)
    return layout.parts.compactMap { placed in
        if case let .table(table) = placed.part { return table }
        return nil
    }
}

@MainActor
func runTranscriptTableSelectionChecks() {
    let gateway = GatewayStore(profile: GatewayProfile(name: "Checks", url: "ws://127.0.0.1:1", authMode: .none))
    let source = "| Name | Note |\n| --- | --- |\n| **Ada** | `code` |\n| [Grace](https://example.com) | *second* |"
    let tables = renderedTables(source, gateway: gateway)
    check(tables.count == 1, "a Markdown table renders as one table part")
    guard let table = tables.first else { return }
    let model = TranscriptTableText(table: table)
    let full = "Name\tNote\nAda\tcode\nGrace\tsecond"
    check(model.string as String == full, "table text is rendered cells joined by tabs and newlines, no markers")
    check(model.text(in: NSRange(location: 0, length: model.length)) == full, "a full selection copies the whole table")

    let start = model.range(row: 1, column: 0).location + 1
    let end = model.range(row: 2, column: 1).location + 3
    check(model.text(in: NSRange(location: start, length: end - start)) == "da\tcode\nGrace\tsec",
          "a selection from the middle of one cell to the middle of another keeps tabs and newlines")
    check(model.text(in: NSRange(location: model.length - 1, length: 99)) == "d", "text(in:) clamps to the table")
    check(model.text(in: model.rowRange(at: model.range(row: 1, column: 1).location)) == "Ada\tcode", "a row selection is tab separated")
    for row in 0..<3 {
        for column in 0..<2 {
            let range = model.range(row: row, column: column)
            let found = model.cell(containing: range.location)
            check(found.row == row && found.column == column, "cell (\(row),\(column)) round-trips")
            let word = model.text(in: model.wordRange(at: range.location))
            check(!word.contains("\t") && !word.contains("\n"), "a word in cell (\(row),\(column)) never crosses a separator")
        }
    }
    let size = table.contentSize
    check(model.offset(at: CGPoint(x: size.width + 100, y: size.height + 100)) == model.length, "a point past the corner clamps to the end")
    check(!model.selectionRects(for: NSRange(location: 0, length: model.length)).isEmpty, "a full selection highlights")

    let cells = [["a\tb", "c\nd"]].map { $0.map { NSAttributedString(string: $0) } }
    let odd = TranscriptPart.Table(cells: cells, columnWidths: [100, 100], rowHeights: [30], plainText: "a b\tc d")
    check(TranscriptTableText(table: odd).string as String == "a b\tc d", "separators inside a cell become spaces")
}

@MainActor
func runDemoTranscriptTableSelectionChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for table selection") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for table selection connected")
    defer { gateway.stop() }
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let before = chat.entries.count
    await chat.send("long")
    let done = await waitFor("long demo reply for table selection", timeout: 30, every: 10) { !chat.isRunning && chat.entries.count > before }
    check(done, "the demo's long reply finished")
    guard case let .assistant(turn)? = chat.entries.last else {
        check(false, "the demo's long reply is an assistant turn")
        return
    }
    check(turn.body.contains("| --- |"), "the demo seeds a Markdown table")
    let tables = renderedTables(turn.body, gateway: gateway)
    guard let table = tables.first else {
        check(false, "the demo's table renders as a table part")
        return
    }
    let model = TranscriptTableText(table: table)
    let expected = table.cells.map { $0.map(\.string).joined(separator: "\t") }.joined(separator: "\n")
    check(table.cells.count >= 2 && (table.cells.first?.count ?? 0) >= 2, "the demo table has a header, rows and columns")
    check(model.text(in: NSRange(location: 0, length: model.length)) == expected,
          "the demo table's full selection is its rendered cells, tab and newline separated")
    check(!expected.contains("|") && !expected.contains("*"), "the demo table's selection carries no Markdown markers")
    for row in table.cells.indices {
        check(model.text(in: model.rowRange(at: model.range(row: row, column: 0).location)) == table.cells[row].map(\.string).joined(separator: "\t"),
              "demo table row \(row) selects as tab-separated text")
    }
    check(!model.selectionRects(for: NSRange(location: 0, length: model.length)).isEmpty, "the demo table highlights when selected")
}
#else
@MainActor func runTranscriptTableSelectionChecks() {}
@MainActor func runDemoTranscriptTableSelectionChecks() async {}
#endif
