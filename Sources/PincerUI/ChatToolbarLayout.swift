import SwiftUI

/// Geometry of the chat header's toolbar controls (#1088). Constants only, so the header costs no
/// extra work to lay out.
enum ChatToolbarLayout {
    /// The widest the model picker's title gets. A longer model name truncates in the middle, so
    /// its provider prefix and version suffix both stay readable; the full name stays in the help
    /// tag and the accessibility value.
    static let modelLabelMaxWidth: CGFloat = 180
    static let modelLabelTruncation: Text.TruncationMode = .middle

    /// On iPad the model and thinking pickers are separate toolbar items, so the glass group spaces
    /// them like its other controls and can fold either one into its overflow on its own. The macOS
    /// window toolbar keeps them in one stable item (#262).
    static func separatesModelAndThinkingItems(isMac: Bool) -> Bool { !isMac }
}

/// The model picker's header label: a bounded title that truncates instead of crowding the header (#1088).
struct ModelPickerLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(self.title)
                .lineLimit(1)
                .truncationMode(ChatToolbarLayout.modelLabelTruncation)
                .frame(maxWidth: ChatToolbarLayout.modelLabelMaxWidth)
        } icon: {
            Image(systemName: "cpu")
        }
        .labelStyle(.titleAndIcon)
    }
}

/// The Runs button's icon: the glyph centred like every other toolbar icon, with the running-helper
/// count as a badge drawn over its top-trailing corner (#1088).
struct RunsToolbarIcon: View {
    let running: Int
    var layout: Layout = Self.layout(isMac: Self.isMac)

    enum Layout: Equatable {
        /// The glyph alone sizes the item, so the toolbar centres it like Browser and Chat Options;
        /// the badge is an overlay that takes no space.
        case centeredGlyphOverlayBadge
        /// A 28pt square with room for the badge, for the macOS toolbar, which clips an item to its frame.
        case reservedBadgeSquare
    }

    static func layout(isMac: Bool) -> Layout { isMac ? .reservedBadgeSquare : .centeredGlyphOverlayBadge }

    static let glyph = "point.3.connected.trianglepath.dotted"
    static let badgeAlignment: Alignment = .topTrailing
    /// How far the overlaid badge sits past the glyph's top-trailing corner.
    static let badgeOffset = CGSize(width: 8, height: -7)

    static func badgeText(running: Int) -> String? {
        guard running > 0 else { return nil }
        return running > 99 ? "99+" : "\(running)"
    }

    var body: some View {
        switch self.layout {
        case .reservedBadgeSquare:
            ZStack(alignment: Self.badgeAlignment) {
                Image(systemName: Self.glyph)
                    .frame(width: 18, height: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                self.badge
            }
            .frame(width: 28, height: 28)
        case .centeredGlyphOverlayBadge:
            Image(systemName: Self.glyph)
                .overlay(alignment: Self.badgeAlignment) {
                    self.badge.offset(Self.badgeOffset)
                }
        }
    }

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @ViewBuilder private var badge: some View {
        if let text = Self.badgeText(running: self.running) {
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .padding(.horizontal, self.running > 9 ? 3 : 0)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}
