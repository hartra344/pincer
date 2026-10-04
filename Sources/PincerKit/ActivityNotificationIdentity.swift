import Foundation

/// Shared fallback identity for activity notifications; explicit reply dedupe remains separate.
enum ActivityNotificationIdentity {
    static func make(key: String, activityMs: Double) -> String {
        let timestamp: String
        if let integer = Int(exactly: activityMs.rounded(.towardZero)) { timestamp = String(integer) }
        else { timestamp = String(activityMs) }
        return "reply:\(key):\(timestamp)"
    }
}
