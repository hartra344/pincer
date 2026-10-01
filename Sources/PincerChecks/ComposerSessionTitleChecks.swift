import Foundation
import PincerKit

@MainActor
func runComposerSessionTitleChecks() {
    let key = "agent:main:dashboard:alpha"
    let current = SessionRow(json(#"{"key":"agent:main:dashboard:alpha","label":"New title"}"#))!
    let old = SessionRow(json(#"{"key":"agent:main:dashboard:alpha","label":"Old title"}"#))!
    let other = SessionRow(json(#"{"key":"agent:main:dashboard:beta","label":"Beta"}"#))!

    check(ComposerSessionTitle.title(sessionKey: key, current: current, lastKnown: old) == "New title",
          "current row title wins after a chat is retitled")
    check(ComposerSessionTitle.title(sessionKey: key, current: nil, lastKnown: old) == "Old title",
          "a matching last-known title survives a nil refresh")
    check(ComposerSessionTitle.title(sessionKey: key, current: other, lastKnown: old) == "Old title",
          "a current row for another chat cannot label this composer")
    check(ComposerSessionTitle.title(sessionKey: key, current: other, lastKnown: nil) == nil,
          "another chat's title is never borrowed")
}

@MainActor
func runDemoComposerSessionTitleChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    defer { gateway.stop() }

    let key = "agent:main:dashboard:garden"
    let ready = await waitFor("seeded Garden planner row") { gateway.sessions[key]?.title == "Garden planner" }
    check(ready, "demo connects with its Garden planner session seed")
    guard ready, let row = gateway.sessions[key] else { return }
    check(ComposerSessionTitle.title(sessionKey: key, current: nil, lastKnown: row) == "Garden planner",
          "demo composer keeps the seeded garden chat title during refresh")
    check(ComposerSessionTitle.title(sessionKey: key, current: row, lastKnown: nil) == row.title,
          "demo composer uses the seeded garden chat's current title")
}
