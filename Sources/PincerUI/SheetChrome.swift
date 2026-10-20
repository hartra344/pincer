import SwiftUI

/// A sheet's leading toolbar button (`.cancellationAction`): "Cancel" by default, or "Close"/"Done"
/// where the sheet has nothing to discard.
struct SheetCancelToolbarItem: ToolbarContent {
    var title: String = L("Cancel")
    var action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button(self.title, action: self.action) }
    }
}

/// A sheet's trailing "Done" toolbar button (`.confirmationAction`).
struct SheetDoneToolbarItem: ToolbarContent {
    var title: String = L("Done")
    var action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button(self.title, action: self.action) }
    }
}

/// The chrome of the composer-adjacent cards (progress, question): a glass surface clipped to a
/// continuous rounded rectangle, inset from the edges and from the content above.
struct ChatCardChrome: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassSurface(in: RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous))
            .padding(.horizontal, Theme.Spacing.row)
            .padding(.top, Theme.Spacing.sm)
    }
}

extension View {
    /// The bottom capsule toast chrome: glass capsule, lifted off the bottom edge, sliding in from it.
    func bottomToastChrome() -> some View {
        self.padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.lg)
            .glassSurface(in: Capsule())
            .padding(.bottom, Theme.Spacing.section)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    func chatCardChrome(cornerRadius: CGFloat) -> some View {
        self.modifier(ChatCardChrome(cornerRadius: cornerRadius))
    }
}
