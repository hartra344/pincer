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
    let (defaults, defaultsName) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    defer {
        gateway.stop()
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }

    let key = "agent:main:dashboard:garden"
    let otherKey = "agent:main:dashboard:trip"
    let ready = await waitFor("seeded Garden planner and Kyoto trip rows") {
        gateway.sessions[key]?.title == "Garden planner" && gateway.sessions[otherKey] != nil
    }
    check(ready, "demo connects with its Garden planner and Kyoto trip session seeds")
    guard ready, let row = gateway.sessions[key], let other = gateway.sessions[otherKey] else { return }
    check(ComposerSessionTitle.title(sessionKey: key, current: nil, lastKnown: row) == "Garden planner",
          "demo composer keeps the seeded garden chat title during refresh")
    check(ComposerSessionTitle.title(sessionKey: key, current: row, lastKnown: nil) == row.title,
          "demo composer uses the seeded garden chat's current title")
    check(ComposerSessionTitle.title(sessionKey: key, current: other, lastKnown: row) == "Garden planner",
          "demo composer ignores a current row belonging to another chat")
    check(ComposerSessionTitle.title(sessionKey: key, current: other, lastKnown: nil) == nil,
          "demo composer never borrows another seeded chat's title")
}
