import Foundation

/// The saved values consumed by Notifications settings; no formatting or clock substitution.
package struct BackgroundRefreshLastCheck: Equatable {
    package let date: Date?
    package let result: String
    package init(defaults: UserDefaults = .standard) {
        date = defaults.object(forKey: "pincer.refresh.lastRun") as? Date
        result = defaults.string(forKey: "pincer.refresh.lastResult") ?? ""
    }
}
