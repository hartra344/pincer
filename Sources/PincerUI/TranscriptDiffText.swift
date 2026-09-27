import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Colors and text of a file edit's diff in a tool card. Colors resolve per appearance when drawn;
/// fonts come from `TranscriptStyle`, so Dynamic Type applies.
@MainActor
enum TranscriptDiffText {
    // systemGreen / systemRed are too faint on white (about 2.2:1 and 3.6:1), so light mode uses
    // darker shades that pass 4.5:1; dark mode keeps the system colors.
    static let addition = adaptive(light: (0x1A, 0x7F, 0x37), dark: .systemGreen)
    static let deletion = adaptive(light: (0xCF, 0x22, 0x2E), dark: .systemRed)

    private static func adaptive(light rgb: (Int, Int, Int), dark: PColor) -> PColor {
        let (r, g, b) = (CGFloat(rgb.0) / 255, CGFloat(rgb.1) / 255, CGFloat(rgb.2) / 255)
        #if os(macOS)
        let light = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        #else
        let light = UIColor(red: r, green: g, blue: b, alpha: 1)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }

    /// The rows one per line, in the same strings Find counts (`ToolFileEdit.text(for:)`).
    static func text(_ rows: [ToolFileEdit.Row]) -> NSAttributedString {
        let style = TranscriptStyle.shared
        let font = style.code
        let bold = PFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        // Wrapped code lines continue under the text, past the +/- sign.
        let signWidth = ceil(NSAttributedString(string: "+", attributes: [.font: font]).size().width)
        let lineParagraph = NSMutableParagraphStyle()
        lineParagraph.lineBreakMode = .byCharWrapping
        lineParagraph.headIndent = signWidth
        let plainParagraph = NSMutableParagraphStyle()
        plainParagraph.lineBreakMode = .byCharWrapping

        let out = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            let string = ToolFileEdit.text(for: row) + (index < rows.count - 1 ? "\n" : "")
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: plainParagraph]
            switch row {
            case let .line(line):
                attributes[.paragraphStyle] = lineParagraph
                attributes[.foregroundColor] = switch line.kind {
                case .addition: self.addition
                case .deletion: self.deletion
                case .context: TranscriptColors.secondary
                }
            case .file:
                attributes[.font] = bold
                attributes[.foregroundColor] = TranscriptColors.label
            case .separator, .truncated:
                attributes[.foregroundColor] = TranscriptColors.tertiary
            }
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        return out
    }

    /// SF Symbol for the card's header.
    static func symbol(for edit: ToolFileEdit) -> String {
        guard edit.files.count == 1 else { return "doc.on.doc" }
        switch edit.files[0].operation {
        case .add: return "doc.badge.plus"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .update: return "pencil"
        }
    }
}
