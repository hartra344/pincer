import SwiftUI

/// A masked field for pasting an API key. iOS offers the Passwords bar and Strong Password on a SwiftUI
/// `SecureField`, so on iOS this wraps a `UITextField` that opts out of AutoFill. macOS keeps `SecureField`.
struct APIKeyField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        #if os(iOS)
        APIKeyTextField(title: self.title, prompt: self.prompt, text: self.$text, onSubmit: self.onSubmit)
            .accessibilityLabel(self.title)
        #else
        SecureField(self.title, text: self.$text, prompt: Text(self.prompt))
            .textContentType(nil)
            .autocorrectionDisabled()
            .onSubmit(self.onSubmit)
        #endif
    }
}

#if os(iOS)
import UIKit

private struct APIKeyTextField: UIViewRepresentable {
    let title: String
    let prompt: String
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.isEnabled = self.isEnabled
        field.isSecureTextEntry = true
        // .oneTimeCode is the content type that keeps the Passwords bar and Strong Password away.
        field.textContentType = .oneTimeCode
        field.passwordRules = nil
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        field.keyboardType = .asciiCapable
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = self.prompt
        field.accessibilityLabel = self.title
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = self.isEnabled
        if field.text != self.text { field.text = self.text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: APIKeyTextField
        init(_ parent: APIKeyTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { self.parent.text = field.text ?? "" }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            self.parent.onSubmit()
            field.resignFirstResponder()
            return true
        }
    }
}
#endif
