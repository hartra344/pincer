import SwiftUI

/// The "needs Full Management" block for settings forms: a lock label, a caption message, optional
/// extra content and an action button (Open Connection by default at the call sites).
struct FullManagementNotice<Extra: View>: View {
    let title: String
    let message: Text
    let extra: Extra
    let action: () -> Void

    init(title: String, message: Text, action: @escaping () -> Void, @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.message = message
        self.action = action
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label(self.title, systemImage: "lock.shield")
                .font(.callout.weight(.medium))
            self.message.font(.caption).foregroundStyle(.secondary)
            self.extra
            Button(L("Open Connection"), action: self.action)
        }
    }
}

extension FullManagementNotice where Extra == EmptyView {
    init(title: String, message: Text, action: @escaping () -> Void) {
        self.init(title: title, message: message, action: action) { EmptyView() }
    }
}

/// The full-pane variant: a `ContentUnavailableView` with a lock label, message, optional extra
/// content and an action button.
struct FullManagementUnavailable<Message: View, Extra: View>: View {
    let title: String
    let systemImage: String
    let message: Message
    let extra: Extra
    let buttonTitle: String
    let action: () -> Void

    init(title: String, systemImage: String = "lock.shield", message: Message, action: @escaping () -> Void,
         @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.buttonTitle = L("Open Connection")
        self.action = action
        self.extra = extra()
    }

    var body: some View {
        ContentUnavailableView {
            Label(self.title, systemImage: self.systemImage)
        } description: {
            self.message
        } actions: {
            self.extra
            Button(self.buttonTitle, action: self.action)
        }
    }
}

extension FullManagementUnavailable where Extra == EmptyView {
    init(title: String, systemImage: String = "lock.shield", message: Message, action: @escaping () -> Void) {
        self.init(title: title, systemImage: systemImage, message: message, action: action) { EmptyView() }
    }
}
