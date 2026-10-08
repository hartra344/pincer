import PincerKit
import SwiftUI

struct PrivacySupportLinks: View {
    var body: some View {
        HStack {
            Link(L("Privacy Policy"), destination: AppLinks.privacy)
            Spacer()
            Link(L("Help & Support"), destination: AppLinks.support)
        }
        .font(.callout)
    }
}

struct PrivacySupportSettingsSection: View {
    var body: some View {
        Section {
            Link(destination: AppLinks.privacy) {
                Label(L("Privacy Policy"), systemImage: "hand.raised")
            }
            Link(destination: AppLinks.support) {
                Label(L("Help & Support"), systemImage: "questionmark.circle")
            }
        } header: {
            Text("Privacy & Support", bundle: .module)
        }
    }
}
