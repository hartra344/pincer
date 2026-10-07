import Foundation

/// Holds one value for the chat a long-lived view currently shows, and makes a fresh one when the
/// chat changes (#571). The chat view keeps its identity across chat switches, so its expensive
/// subtree (the transcript's table, the composer) is reused, while per-chat state such as Find,
/// open sheets and the jump target still starts over, as a new `@State` would.
///
/// Keep it in `@State` and read it from `body`: the switch to the new value happens in the same
/// render that shows the new chat, so the old chat's state is never drawn over it. It isn't
/// observable itself; the values it holds are.
@MainActor
final class ChatScoped<Value: AnyObject> {
    private(set) var key: String?
    private var value: Value?
    /// The value the last switch replaced, until `takeRetired()` collects it for clean-up.
    private var retired: Value?

    init() {}

    /// The value for `key`, made with `make` when `key` isn't the current chat.
    func value(for key: String, make: () -> Value) -> Value {
        if let value, self.key == key { return value }
        if let value { self.retired = value }
        let fresh = make()
        self.key = key
        self.value = fresh
        return fresh
    }

    /// The previous chat's value after a switch, once, so its work can be cancelled.
    func takeRetired() -> Value? {
        defer { self.retired = nil }
        return self.retired
    }
}
