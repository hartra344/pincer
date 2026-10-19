import SwiftUI

/// The "Not Connected" empty state shared by Settings pages; callers supply their own message `Text`.
struct NotConnectedView: View {
    let description: Text

    var body: some View {
        ContentUnavailableView(L("Not Connected"), systemImage: "bolt.horizontal.circle", description: self.description)
    }
}

/// A Settings section showing a load error with a "Try Again" button.
struct LoadErrorSection: View {
    let error: String
    var canRetry = true
    let retry: () -> Void

    var body: some View {
        Section {
            Label(self.error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            Button(L("Try Again"), action: self.retry)
                .disabled(!self.canRetry)
        }
    }
}

/// A selectable load error with a retry button, for use inside a `Section`.
struct LoadErrorRetryBlock: View {
    let error: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label(self.error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            Button(L("Retry"), action: self.retry)
        }
    }
}
