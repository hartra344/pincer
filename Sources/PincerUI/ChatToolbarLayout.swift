import SwiftUI

/// Geometry of the chat header's toolbar controls (#1088). Constants only, so the header costs no
/// extra work to lay out.
enum ChatToolbarLayout {
    /// The widest the model picker's title gets. A longer model name truncates in the middle, so
    /// its provider prefix and version suffix both stay readable; the full name stays in the help
    /// tag and the accessibility value.
    static let modelLabelMaxWidth: CGFloat = 180
    static let modelLabelTruncation: Text.TruncationMode = .middle
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
/// count as a badge in the square's top-trailing corner (#1088).
struct RunsToolbarIcon: View {
    let running: Int
    var layout: Layout = Self.layout(isMac: Self.isMac)

    enum Layout: Equatable {
        /// iOS: the glyph centred in the square, so the glass group spaces it like Browser and Chat
        /// Options. The badge stays inside the square's height: the bar clips an item to its frame.
        case centeredGlyph
        /// macOS: the glyph in the bottom-leading corner, leaving the badge its own corner.
        case bottomLeadingGlyph
    }

    static func layout(isMac: Bool) -> Layout { isMac ? .bottomLeadingGlyph : .centeredGlyph }

    static let glyph = "point.3.connected.trianglepath.dotted"
    /// The icon's square, the same with or without a badge, so the toolbar never re-lays out when helpers start.
    static let side: CGFloat = 28
    static let glyphSide: CGFloat = 18
    static let badgeSide: CGFloat = 16
    static let badgeAlignment: Alignment = .topTrailing
    /// How far the badge reaches past the square's trailing edge on iOS, into the bar item's own
    /// padding (about 5pt). Never past its top: the item is exactly as tall as the square.
    static let badgeOverhang: CGFloat = 3

    static func badgeText(running: Int) -> String? {
        guard running > 0 else { return nil }
        return running > 99 ? "99+" : "\(running)"
    }

    var body: some View {
        ZStack(alignment: Self.badgeAlignment) {
            Image(systemName: Self.glyph)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: self.layout == .centeredGlyph ? .center : .bottomLeading)
            self.badge.offset(x: self.layout == .centeredGlyph ? Self.badgeOverhang : 0)
        }
        .frame(width: Self.side, height: Self.side)
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
                .frame(minWidth: Self.badgeSide, minHeight: Self.badgeSide)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}
