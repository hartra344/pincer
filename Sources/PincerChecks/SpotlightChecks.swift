import Foundation
import PincerKit

@MainActor
func runSpotlightChecks() {
    let suite = "pincer-checks-spotlight-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    check(Spotlight.canPublish(includeMessages: false, defaults: defaults),
          "an unchanged Spotlight privacy snapshot may publish")
    defaults.set(true, forKey: Spotlight.includeMessagesKey)
    check(!Spotlight.canPublish(includeMessages: false, defaults: defaults),
          "an in-flight message-free reindex is rejected after message indexing is enabled")
    check(Spotlight.canPublish(includeMessages: true, defaults: defaults),
          "an in-flight opted-in reindex may publish while that preference remains enabled")
    defaults.set(false, forKey: Spotlight.includeMessagesKey)
    check(!Spotlight.canPublish(includeMessages: true, defaults: defaults),
          "an in-flight opted-in reindex is rejected after message indexing is disabled")
    check(Spotlight.canPublish(includeMessages: false, defaults: defaults),
          "an unchanged message-free reindex may publish")
    defaults.set(false, forKey: Spotlight.enabledKey)
    check(!Spotlight.canPublish(includeMessages: false, defaults: defaults),
          "an in-flight reindex is rejected after Spotlight is disabled")

    let key = "agent:main:dashboard:same-title"
    let row = SessionRow(.object(["key": .string(key), "label": .string("Planning"), "lastActivityAt": .number(42)]))!
    let sessions = [row]
    let snippets = [key: "private local excerpt"]
    let personal = Spotlight.entries(gatewayId: UUID(), gatewayName: "Personal", sessions: sessions,
                                     cachedSnippets: snippets, includeMessages: false)[0]
    let work = Spotlight.entries(gatewayId: UUID(), gatewayName: "Work", sessions: sessions,
                                 cachedSnippets: snippets, includeMessages: false)[0]
    check(personal.title == work.title && personal.contentDescription == "Personal"
          && work.contentDescription == "Work",
          "same-title Spotlight chats are disambiguated by Gateway name")
    check(personal.snippet == nil && !((personal.contentDescription ?? "").contains("private local excerpt")),
          "Gateway name is indexed without message text by default")

    let included = Spotlight.entries(gatewayId: UUID(), gatewayName: "Personal", sessions: sessions,
                                    cachedSnippets: snippets, includeMessages: true)[0]
    check(included.contentDescription == "Personal · private local excerpt",
          "Spotlight appends cached message text only when enabled")
}
