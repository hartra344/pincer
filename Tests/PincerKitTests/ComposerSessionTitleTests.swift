import Foundation
import Testing
@testable import PincerKit

@Suite("Composer session title")
struct ComposerSessionTitleTests {
    private func row(_ key: String, _ title: String) -> SessionRow {
        SessionRow(.object(["key": .string(key), "label": .string(title)]))!
    }

    @Test func currentRowWinsAfterRetitle() {
        let current = self.row("agent:main:dashboard:alpha", "New title")
        let lastKnown = self.row(current.key, "Old title")
        #expect(ComposerSessionTitle.title(sessionKey: current.key, current: current, lastKnown: lastKnown) == "New title")
    }

    @Test func matchingLastKnownRowSurvivesMissingCurrentRow() {
        let cached = self.row("agent:main:dashboard:alpha", "Alpha")
        #expect(ComposerSessionTitle.title(sessionKey: cached.key, current: nil, lastKnown: cached) == "Alpha")
    }

    @Test func matchingLastKnownRowWinsOverCurrentRowFromAnotherChat() {
        let cached = self.row("agent:main:dashboard:alpha", "Alpha")
        let other = self.row("agent:main:dashboard:beta", "Beta")
        #expect(ComposerSessionTitle.title(sessionKey: cached.key, current: other, lastKnown: cached) == "Alpha")
    }

    @Test func mismatchedRowsNeverLabelSelectedChat() {
        let current = self.row("agent:main:dashboard:beta", "Beta")
        let lastKnown = self.row("agent:main:dashboard:alpha", "Alpha")
        #expect(ComposerSessionTitle.title(sessionKey: "agent:main:dashboard:gamma", current: current, lastKnown: lastKnown) == nil)
    }

    @Test func missingCurrentAndLastKnownRowsReturnNil() {
        #expect(ComposerSessionTitle.title(sessionKey: "agent:main:dashboard:alpha", current: nil, lastKnown: nil) == nil)
    }
}
