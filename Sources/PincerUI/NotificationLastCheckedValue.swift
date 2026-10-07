import PincerKit
import SwiftUI

/// "Last checked" value in Notifications settings. A minute timeline keeps the relative age
/// ("5 minutes ago") current while the page stays open, without a per-second ticking label.
struct NotificationLastCheckedValue: View {
    let saved: BackgroundRefreshLastCheck
    var body: some View {
        Group {
            if let date = self.saved.date {
                TimelineView(.everyMinute) { _ in
                    let when = date.formatted(.relative(presentation: .named))
                    Text(self.saved.result.isEmpty ? when : "\(when) · \(self.saved.result)")
                }
            } else {
                Text("Not yet")
            }
        }.accessibilityIdentifier("notification-last-checked-value")
    }
}
