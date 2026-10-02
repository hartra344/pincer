import PincerKit
import SwiftUI

/// Isolates display-name keystrokes from the rest of the Settings form's AppStorage bindings.
struct OwnerNameSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SwiftUI.Section {
            TextField(
                L("Display name"),
                text: Binding(
                    get: { self.app.ownerNameDraft.text },
                    set: { self.app.ownerNameDraft.update($0) }
                ),
                prompt: Text(Owner.displayName)
            )
            .onSubmit { Task { await self.app.ownerNameDraft.flush() } }
        } header: {
            Text("You", bundle: .module)
        } footer: {
            Text("Your messages show under this name, whichever channel they came from.", bundle: .module)
        }
        .onDisappear { Task { await self.app.ownerNameDraft.flush() } }
    }
}
