import CoreGraphics
import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The fonts message text is built with, copied out of `TranscriptStyle` so a background thread
/// never touches the main-actor style object. Fonts are immutable, so sharing them is safe.
struct TranscriptFonts: @unchecked Sendable {
    let body: PFont
    let bodySemibold: PFont
    let headline: PFont
    let code: PFont
    let title2: PFont
    let title3: PFont
    let listMarker: PFont

    @MainActor init(_ style: TranscriptStyle) {
        self.body = style.body
        self.bodySemibold = style.bodySemibold
        self.headline = style.headline
        self.code = style.code
        self.title2 = style.title2
        self.title3 = style.title3
        self.listMarker = style.listMarker
    }
}

/// Everything `TranscriptText.build` reads from main-actor state, captured once. Text runs carry
/// dynamic system colors that resolve when drawn, so segments and their heights don't depend on
/// the appearance; `dark` only keys the caches, because inline math bakes a resolved color.
struct TextBuildEnvironment: @unchecked Sendable {
    let fonts: TranscriptFonts
    let colors: (primary: PColor, secondary: PColor, error: PColor, fill: PColor)
    let styleGeneration: Int
    let dark: Bool

    @MainActor private static var memo: TextBuildEnvironment?

    @MainActor static func current(dark: Bool) -> TextBuildEnvironment {
        if let memo, memo.styleGeneration == TranscriptStyle.generation, memo.dark == dark { return memo }
        let made = TextBuildEnvironment(
            fonts: TranscriptFonts(TranscriptStyle.shared),
            colors: (TranscriptColors.label, TranscriptColors.secondary, TranscriptColors.red, TranscriptColors.fill),
            styleGeneration: TranscriptStyle.generation, dark: dark)
        self.memo = made
        return made
    }

    func color(for tone: TranscriptText.Tone) -> PColor {
        switch tone {
        case .primary: self.colors.primary
        case .secondary: self.colors.secondary
        case .error: self.colors.error
        }
    }
}

/// One private TextKit 1 stack. The main thread owns one and the premeasure worker owns another;
/// a stack is never shared, and never attached to a view, so neither needs a lock. Configured like
/// the stacks row views draw with (`TranscriptTextKit.stack`), so heights match what is drawn.
final class TranscriptTextMeasurer {
    private let storage = NSTextStorage()
    private let container = NSTextContainer(size: .zero)

    nonisolated init() {
        let manager = NSLayoutManager()
        self.container.lineFragmentPadding = 0
        manager.addTextContainer(self.container)
        self.storage.addLayoutManager(manager)
    }

    /// Size of `string` wrapped to `width` (unwrapped when width is infinite), rounded up to points
    /// unless `exact`.
    nonisolated func size(_ string: NSAttributedString, width: CGFloat, exact: Bool = false) -> CGSize {
        guard string.length > 0, width > 0 else { return .zero }
        let manager = self.container.layoutManager!
        self.container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        self.storage.setAttributedString(string)
        manager.ensureLayout(for: self.container)
        let used = manager.usedRect(for: self.container)
        return exact ? CGSize(width: ceil(used.width), height: used.height) : CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// Width of `string` on one line, ignoring paragraph alignment.
    nonisolated func naturalWidth(_ string: NSAttributedString) -> CGFloat {
        guard string.length > 0 else { return 0 }
        let unaligned = NSMutableAttributedString(attributedString: string)
        unaligned.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: unaligned.length))
        return self.size(unaligned, width: .greatestFiniteMagnitude).width
    }
}
