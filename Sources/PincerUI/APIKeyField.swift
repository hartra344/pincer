import SwiftUI

/// A masked field for pasting an API key. iOS opts out of Passwords/Strong Password autofill;
/// both platforms can reveal the unsaved text while keeping text and selection in the same host.
struct APIKeyField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @State private var isRevealed = false

    var body: some View {
        #if os(iOS)
        APIKeyIOSField(title: self.title, prompt: self.prompt, text: self.$text,
                       isRevealed: self.$isRevealed, onSubmit: self.onSubmit)
        #else
        APIKeyMacField(title: self.title, prompt: self.prompt, text: self.$text,
                       isRevealed: self.$isRevealed, onSubmit: self.onSubmit)
        #endif
    }
}

#if os(iOS)
import UIKit

private struct APIKeyIOSField: UIViewRepresentable {
    let title: String
    let prompt: String
    @Binding var text: String
    @Binding var isRevealed: Bool
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> APIKeyIOSFieldView {
        let view = APIKeyIOSFieldView()
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

        view.textField = field
        view.visibilityButton.accessibilityIdentifier = "api-key-visibility"
        view.visibilityButton.addTarget(context.coordinator, action: #selector(Coordinator.toggleVisibility), for: .touchUpInside)
        context.coordinator.field = field
        context.coordinator.updateVisibilityButton(view.visibilityButton)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.addArrangedSubview(field)
        view.addArrangedSubview(view.visibilityButton)
        return view
    }

    func updateUIView(_ view: APIKeyIOSFieldView, context: Context) {
        guard let field = view.textField else { return }
        context.coordinator.parent = self
        context.coordinator.field = field
        field.isEnabled = self.isEnabled
        if field.text != self.text { field.text = self.text }
        context.coordinator.updateVisibilityButton(view.visibilityButton)
        context.coordinator.applySecureEntry(to: field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: APIKeyIOSField
        weak var field: UITextField?
        init(_ parent: APIKeyIOSField) { self.parent = parent }

        func updateVisibilityButton(_ button: UIButton?) {
            guard let button else { return }
            let label = self.parent.isRevealed ? L("Hide API key") : L("Show API key")
            button.accessibilityLabel = label
            button.isEnabled = self.parent.isEnabled
            button.setImage(UIImage(systemName: self.parent.isRevealed ? "eye.slash" : "eye"), for: .normal)
        }

        func applySecureEntry(to field: UITextField) {
            let shouldSecure = !self.parent.isRevealed
            guard field.isSecureTextEntry != shouldSecure else { return }

            let text = field.text ?? ""
            let wasFirstResponder = field.isFirstResponder
            let selection = field.selectedTextRange.map {
                (start: field.offset(from: field.beginningOfDocument, to: $0.start),
                 end: field.offset(from: field.beginningOfDocument, to: $0.end))
            }
            field.isSecureTextEntry = shouldSecure
            if field.text != text { field.text = text }
            if wasFirstResponder { _ = field.becomeFirstResponder() }
            if let selection,
               let start = field.position(from: field.beginningOfDocument, offset: selection.start),
               let end = field.position(from: field.beginningOfDocument, offset: selection.end)
            {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
        }

        @objc func toggleVisibility() {
            self.preserveSelectionWhileToggling()
            self.parent.isRevealed.toggle()
        }

        private func preserveSelectionWhileToggling() {
            guard let field = self.field else { return }
            let wasFirstResponder = field.isFirstResponder
            let selection = field.selectedTextRange.map {
                (start: field.offset(from: field.beginningOfDocument, to: $0.start),
                 end: field.offset(from: field.beginningOfDocument, to: $0.end))
            }
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                if wasFirstResponder { _ = field.becomeFirstResponder() }
                if let selection,
                   let start = field.position(from: field.beginningOfDocument, offset: selection.start),
                   let end = field.position(from: field.beginningOfDocument, offset: selection.end)
                {
                    field.selectedTextRange = field.textRange(from: start, to: end)
                }
            }
        }
        @objc func changed(_ field: UITextField) { self.parent.text = field.text ?? "" }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            self.parent.onSubmit()
            field.resignFirstResponder()
            return true
        }
    }
}

@MainActor
private final class APIKeyIOSFieldView: UIStackView {
    let visibilityButton = UIButton(type: .system)
    var textField: UITextField?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.axis = .horizontal
        self.alignment = .center
        self.distribution = .fill
        self.spacing = 4
        self.visibilityButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        self.visibilityButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        self.visibilityButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        self.visibilityButton.contentHorizontalAlignment = .center
        self.visibilityButton.contentVerticalAlignment = .center
        self.visibilityButton.setContentHuggingPriority(.required, for: .horizontal)
        self.visibilityButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#else
import AppKit

private struct APIKeyMacField: NSViewRepresentable {
    let title: String
    let prompt: String
    @Binding var text: String
    @Binding var isRevealed: Bool
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> APIKeyMacFieldView {
        let view = APIKeyMacFieldView()
        for field in [view.secureField, view.plainField] {
            field.target = context.coordinator
            field.action = #selector(Coordinator.submit(_:))
            field.delegate = context.coordinator
        }
        view.visibilityButton.target = context.coordinator
        view.visibilityButton.action = #selector(Coordinator.toggleVisibility(_:))
        context.coordinator.view = view
        view.update(title: self.title, prompt: self.prompt, text: self.text,
                    isRevealed: self.isRevealed, isEnabled: self.isEnabled)
        return view
    }

    func updateNSView(_ view: APIKeyMacFieldView, context: Context) {
        context.coordinator.parent = self
        view.update(title: self.title, prompt: self.prompt, text: self.text,
                    isRevealed: self.isRevealed, isEnabled: self.isEnabled)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: APIKeyMacField
        weak var view: APIKeyMacFieldView?

        init(_ parent: APIKeyMacField) { self.parent = parent }

        @objc func toggleVisibility(_ sender: NSButton) {
            self.view?.prepareVisibilityToggle()
            self.parent.isRevealed.toggle()
        }

        @objc func submit(_ sender: NSTextField) { self.parent.onSubmit() }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            self.parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            APIKeyMacTextInput.configure(editor)
        }
    }
}

@MainActor
private enum APIKeyMacTextInput {
    static func configure(_ text: NSText) {
        guard let editor = text as? NSTextView else { return }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
    }
}

@MainActor
private final class APIKeyPlainTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        APIKeyMacTextInput.configure(editor)
        return editor
    }
}

@MainActor
private final class APIKeySecureTextFieldCell: NSSecureTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        APIKeyMacTextInput.configure(editor)
        return editor
    }
}

@MainActor
private final class APIKeyMacFieldView: NSStackView {
    let secureField = NSSecureTextField(frame: .zero)
    let plainField = NSTextField(frame: .zero)
    let visibilityButton = NSButton(frame: .zero)
    private var isRevealed = false
    private var pendingSelection: NSRange?
    private var pendingFocus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.secureField.cell = APIKeySecureTextFieldCell(textCell: "")
        self.plainField.cell = APIKeyPlainTextFieldCell(textCell: "")
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fill
        self.spacing = 6
        self.detachesHiddenViews = true

        for field in [self.secureField, self.plainField] {
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
            field.placeholderString = ""
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            self.addArrangedSubview(field)
        }
        self.visibilityButton.isBordered = false
        self.visibilityButton.imagePosition = .imageOnly
        self.visibilityButton.setButtonType(.momentaryChange)
        self.visibilityButton.setContentHuggingPriority(.required, for: .horizontal)
        self.visibilityButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.addArrangedSubview(self.visibilityButton)
        self.secureField.isHidden = false
        self.plainField.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepareVisibilityToggle() {
        let field = self.isRevealed ? self.plainField : self.secureField
        let editor = field.currentEditor()
        self.pendingSelection = editor?.selectedRange
        self.pendingFocus = field.window.map { window in
            window.firstResponder === field || (editor != nil && window.firstResponder === editor)
        } ?? false
    }

    func update(title: String, prompt: String, text: String, isRevealed: Bool, isEnabled: Bool) {
        let changedVisibility = self.isRevealed != isRevealed
        if changedVisibility && self.pendingSelection == nil { self.prepareVisibilityToggle() }

        self.setTextIfNeeded(text, in: self.secureField)
        self.setTextIfNeeded(text, in: self.plainField)
        for field in [self.secureField, self.plainField] {
            field.placeholderString = prompt
            field.isEnabled = isEnabled
            field.setAccessibilityLabel(title)
        }
        self.plainField.isHidden = !isRevealed
        self.secureField.isHidden = isRevealed
        self.isRevealed = isRevealed

        let label = isRevealed ? L("Hide API key") : L("Show API key")
        self.visibilityButton.identifier = NSUserInterfaceItemIdentifier("api-key-visibility")
        self.visibilityButton.isEnabled = isEnabled
        self.visibilityButton.setAccessibilityLabel(label)
        self.visibilityButton.toolTip = label
        self.visibilityButton.image = NSImage(systemSymbolName: isRevealed ? "eye.slash" : "eye",
                                              accessibilityDescription: label)

        if changedVisibility {
            if self.pendingFocus {
                let field = isRevealed ? self.plainField : self.secureField
                if field.window?.makeFirstResponder(field) == true,
                   let selection = self.pendingSelection,
                   let editor = field.currentEditor()
                {
                    let length = (text as NSString).length
                    let start = min(selection.location, length)
                    editor.selectedRange = NSRange(location: start, length: min(selection.length, length - start))
                }
            }
            self.pendingSelection = nil
            self.pendingFocus = false
        }
    }

    private func setTextIfNeeded(_ text: String, in field: NSTextField) {
        if field.stringValue != text { field.stringValue = text }
    }
}
#endif
