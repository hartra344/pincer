import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// #195: which row the next/previous message shortcut and the VoiceOver rotors land on.
@MainActor
@Suite("Transcript navigation")
struct TranscriptNavigationTests {
    static func user(_ n: Int) -> TranscriptRow { TranscriptListControllerTests.user(n) }

    static func reply(_ n: Int, tools: Int = 0) -> TranscriptRow {
        var turn = AssistantTurn(id: "a\(n)", timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
        turn.text = ["Reply \(n)"]
        turn.tools = (0..<tools).map { ToolActivity(id: "t\(n)-\($0)", name: "exec", arguments: nil, result: nil, isError: false, isRunning: false) }
        return .entry(.assistant(turn))
    }

    static let marker = TranscriptRow.entry(.marker(id: "m", label: "Today"))

    /// 0 loading, 1 user, 2 reply, 3 marker, 4 user, 5 reply+tool, 6 reply
    static let rows: [TranscriptRow] = [.loadingOlder, user(1), reply(1), marker, user(2), reply(2, tools: 1), reply(3)]

    static func next(_ from: Int?, _ kind: TranscriptNavKind = .message, forward: Bool = true) -> Int? {
        TranscriptListController.adjacentRow(in: rows, from: from, forward: forward, kind: kind)
    }

    @Test func messagesSkipLoadingAndMarkers() {
        #expect(Self.next(nil) == 1)
        #expect(Self.next(1) == 2)
        #expect(Self.next(2) == 4)
        #expect(Self.next(4, forward: false) == 2)
        #expect(Self.next(1, forward: false) == nil)
        #expect(Self.next(6) == nil)
    }

    @Test func fromNilBackwardPicksLast() {
        #expect(Self.next(nil, forward: false) == 6)
        #expect(Self.next(nil, .user, forward: false) == 4)
    }

    @Test func kindsFilterRows() {
        #expect(Self.next(nil, .reply) == 2)
        #expect(Self.next(2, .reply) == 5)
        #expect(Self.next(5, .reply) == 6)
        #expect(Self.next(6, .reply) == nil)
        #expect(Self.next(nil, .user) == 1)
        #expect(Self.next(1, .user) == 4)
        #expect(Self.next(4, .user) == nil)
        #expect(Self.next(nil, .tool) == 5)
        #expect(Self.next(5, .tool) == nil)
        #expect(Self.next(6, .tool, forward: false) == 5)
        #expect(Self.next(5, .tool, forward: false) == nil)
    }

    @Test func emptyAndMarkerOnlyListsHaveNoTarget() {
        #expect(TranscriptListController.adjacentRow(in: [], from: nil, forward: true) == nil)
        #expect(TranscriptListController.adjacentRow(in: [.loadingOlder, Self.marker], from: nil, forward: false) == nil)
    }

    @Test func outOfRangeStartStillFindsARow() {
        #expect(Self.next(3) == 4)
        #expect(Self.next(3, forward: false) == 2)
    }
}
