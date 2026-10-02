import Foundation
import PincerKit

@MainActor
func runOwnerNameChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("Before", forKey: OwnerNameDraft.storageKey)
    let app = AppModel(defaults: defaults)

    app.ownerNameDraft.update("M")
    app.ownerNameDraft.update("Maya Chen")
    check(defaults.string(forKey: OwnerNameDraft.storageKey) == "Before",
          "display name: keystrokes remain in the isolated draft until the idle save or explicit flush")
    await app.ownerNameDraft.flush()
    check(defaults.string(forKey: OwnerNameDraft.storageKey) == "Maya Chen",
          "display name: the settings draft flushes the exact latest value")
}
