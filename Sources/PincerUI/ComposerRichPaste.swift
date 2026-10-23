import Foundation
import PincerKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pasting formatted text (web pages, Notes, Pages…) into the composer as Markdown.
/// The pasteboard is read on the main thread; HTML/RTF parsing and conversion run off it.
enum ComposerRichPaste {
    enum Payload: Sendable {
        case html(String)
        case rtf(Data)
    }

    /// The pasteboard's formatted representation, HTML preferred over RTF; nil when there is only plain text.
    @MainActor
    static func payload(from pasteboard: Pasteboard) -> Payload? {
        if let data = pasteboard.data(for: .html), let html = Self.decodeHTML(data) { return .html(html) }
        if let data = pasteboard.data(for: .rtf) { return .rtf(data) }
        return nil
    }

    /// Small HTML converts right away (the walker is microseconds), so ordinary pastes never wait a turn.
    /// Returns nil when the payload is too big or needs an RTF load; `.some(nil)` means no formatting.
    @MainActor
    static func quickMarkdown(from payload: Payload) -> String?? {
        guard case .html(let html) = payload, html.utf16.count <= 8_192 else { return nil }
        return .some(RichTextToMarkdown.markdown(fromHTML: html))
    }

    /// Markdown for the payload, or nil when it carries no real formatting (paste the plain text instead).
    static func markdown(from payload: Payload) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            switch payload {
            case .html(let html):
                return RichTextToMarkdown.markdown(fromHTML: html)
            case .rtf(let data):
                guard let attributed = try? NSAttributedString(
                    data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                else { return nil }
                return RichTextToMarkdown.markdown(from: attributed)
            }
        }.value
    }

    private static func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1)
    }

    #if os(macOS)
    typealias Pasteboard = NSPasteboard
    #else
    typealias Pasteboard = UIPasteboard
    #endif
}

#if os(macOS)
private extension NSPasteboard {
    func data(for type: UTType) -> Data? { self.data(forType: NSPasteboard.PasteboardType(type.identifier)) }
}
#else
private extension UIPasteboard {
    func data(for type: UTType) -> Data? { self.data(forPasteboardType: type.identifier) }
}
#endif
