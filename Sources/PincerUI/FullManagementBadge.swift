import PincerKit
import SwiftUI

/// "Needs Full Management" with the copy Gateway Settings uses, linking to Connection. Shared by the
/// setup wizard and Channel Status.
struct FullManagementBadge: View {
    let openConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(SetupWizardModel.fullManagementTitle, systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
            Text(SetupWizardModel.fullManagementMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L("Open Connection…"), action: self.openConnection)
                .buttonStyle(.borderless)
                .font(.callout)
        }
    }
}
