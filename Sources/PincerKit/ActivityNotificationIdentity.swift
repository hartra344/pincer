import Foundation

/// Shared fallback identity for activity notifications; explicit reply dedupe remains separate.
enum ActivityNotificationIdentity {
    static func make(key: String, activityMs: Double) -> String {
        let timestamp = activityMs.integerString(rounding: .towardZero) ?? String(activityMs)
        return "reply:\(key):\(timestamp)"
    }
}
