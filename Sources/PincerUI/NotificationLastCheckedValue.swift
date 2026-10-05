import PincerKit
import SwiftUI

/// Actual settings value; SwiftUI keeps the saved check's relative age current.
struct NotificationLastCheckedValue: View {
    let saved: BackgroundRefreshLastCheck
    var body: some View {
        Group {
            if let date = self.saved.date {
                if self.saved.result.isEmpty {
                    Text(date, style: .relative)
                } else {
                    Text(date, style: .relative) + Text(" · \(self.saved.result)")
                }
            } else {
                Text("Not yet")
            }
        }.accessibilityIdentifier("notification-last-checked-value")
    }
}
