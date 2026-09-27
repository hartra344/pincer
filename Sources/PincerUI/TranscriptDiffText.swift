import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Colors and text of a file edit's diff in a tool card. System colors, so dark mode and
/// increased contrast resolve when drawn; fonts come from `TranscriptStyle`, so Dynamic Type applies.
@MainActor
enum TranscriptDiffText {
    static var addition: PColor { .systemGreen }
    static var deletion: PColor { .systemRed }

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
