import PincerKit
import SwiftUI

/// Actual settings value, extracted with the existing static formatting unchanged.
struct NotificationLastCheckedValue: View {
    let saved: BackgroundRefreshLastCheck
    var body: some View {
        Group {
        if let date = self.saved.date {
            let when = date.formatted(.relative(presentation: .named))
            Text(self.saved.result.isEmpty ? when : "\(when) · \(self.saved.result)")
        } else { Text("Not yet") }
        }.accessibilityIdentifier("notification-last-checked-value")
    }
}
