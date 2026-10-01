import Foundation

/// Formats the activity time shown at the trailing edge of a sidebar chat row.
public enum SidebarActivityDate {
    public static func relativeDate(_ date: Date, now: Date = .now) -> String {
        if date >= now { return L("now") }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }
}
