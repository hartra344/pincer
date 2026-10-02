import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum TranscriptWebSearchAccessibility {
    /// Attached only to web-search result/citation title links. The action title uses this safe
    /// host context without speaking the linked URL's path, query, or fragment.
    static let host = NSAttributedString.Key("Pincer.WebSearchAccessibilityHost")
}

extension TranscriptLayoutBuilder {
    /// A web_search result as a link list: each title opens its page, under it the site and the start
    /// of the snippet. An answer shows its text, then its sources. Each entry is one section whose text
    /// is exactly `WebSearch.searchTexts`, so Find matches what's drawn.
    func webSearch(_ web: WebSearch, durationMs: Int?, tool: ToolActivity, into card: inout ToolCardBuild) {
        var badges: [(String, TranscriptPart.Tool.Tone, String)] = []
        if let provider = web.provider { badges.append((provider, .strongFill, L("Provider \(provider)"))) }
        if web.kind == .results {
            let count = web.results.count
            let text = count == 1 ? L("1 result") : L("\(count) results")
            badges.append((text, .strongFill, text))
        }
        if let ms = durationMs {
            let (text, spoken) = ToolDuration.format(ms)
            badges.append((text, .strongFill, spoken))
        }
        if web.cached { badges.append((L("cached"), .strongFill, L("Cached result"))) }
        let title = switch web.kind {
        case .answer: L("Answer")
        case .error: L("Error")
        case .results: L("Results")
        }
        self.titleRow(title, failed: web.kind == .error, badges: badges, copy: web.copyText, searchTool: tool.id, into: &card)
        if card.search != nil {
            card.y += 6
            card.search?.frame = CGRect(x: card.x, y: card.y, width: card.inner, height: 26)
            card.y += 26
        }
        card.y += 4
        switch web.kind {
        case .results:
            for (index, result) in web.results.enumerated() {
                if index > 0 { card.y += 8 }
                self.linkSection("\(tool.id):web-\(index)", result.text, link: result.url, titleLength: result.title.utf16.count,
                                 accessibilityHost: result.url.host(percentEncoded: false), tool: tool, into: &card)
            }
        case .answer:
            if let answer = web.answer {
                card.y += self.textSection("\(tool.id):web-answer", TranscriptText.plain(answer, font: self.style.caption, color: TranscriptColors.label),
                                           tool: tool, x: card.x, width: card.inner, maxHeight: .greatestFiniteMagnitude, into: &card)
            }
            if !web.citations.isEmpty {
                card.y += 8
                let font = self.style.captionSemibold
                card.decor.append(.label(L("Sources"), CGPoint(x: card.x, y: card.y + (self.titleRowHeight - TranscriptStyle.lineHeight(font)) / 2),
                                         width: card.inner, .captionSemibold, .secondary, truncation: .byTruncatingTail))
                card.y += self.titleRowHeight + 4
                for (index, citation) in web.citations.enumerated() {
                    if index > 0 { card.y += 4 }
                    self.linkSection("\(tool.id):web-source-\(index)", citation.label, link: citation.url, titleLength: citation.label.utf16.count,
                                     accessibilityHost: citation.url.host(percentEncoded: false), tool: tool, into: &card)
                }
            }
        case .error:
            if let message = web.message {
                card.y += self.textSection("\(tool.id):web-error", TranscriptText.plain(message, font: self.style.caption, color: TranscriptColors.failure),
                                           tool: tool, x: card.x, width: card.inner, maxHeight: .greatestFiniteMagnitude, into: &card)
            }
            if let docs = web.docs {
                card.y += 8
                self.linkSection("\(tool.id):web-docs", docs.absoluteString, link: docs, titleLength: docs.absoluteString.utf16.count,
                                 tool: tool, into: &card)
            }
        }
        if web.truncated && (web.kind == .results || web.kind == .answer) {
            let text = L("Search output was truncated")
            let font = self.style.caption
            let height = TranscriptStyle.lineHeight(font)
            card.y += 8
            card.decor.append(.label(text, CGPoint(x: card.x, y: card.y), width: card.inner,
                                     .caption, .secondary, truncation: .byTruncatingTail))
            card.notes.append(.init(frame: CGRect(x: card.x, y: card.y, width: card.inner, height: height), text: text))
            card.y += height
        }
    }

    /// `text` with its first `titleLength` UTF-16 units as the link, then the meta line (dimmer) and snippet.
    private func linkSection(_ id: String, _ text: String, link: URL, titleLength: Int, accessibilityHost: String? = nil,
                             tool: ToolActivity,
                             into card: inout ToolCardBuild)
    {
        let style = self.style
        let string = NSMutableAttributedString(string: text, attributes: [.font: style.caption, .foregroundColor: TranscriptColors.secondary])
        let titleRange = NSRange(location: 0, length: min(titleLength, string.length))
        var titleAttributes: [NSAttributedString.Key: Any] = [.font: style.callout, .foregroundColor: TranscriptColors.link, .link: link]
        if let accessibilityHost, !accessibilityHost.isEmpty {
            titleAttributes[TranscriptWebSearchAccessibility.host] = accessibilityHost
        }
        #if os(macOS)
        titleAttributes[.toolTip] = link.absoluteString
        #endif
        string.addAttributes(titleAttributes, range: titleRange)
        // The meta line is the second line; leave it in the dimmer secondary.
        let nsText = text as NSString
        let metaStart = titleRange.length + 1
        if metaStart < nsText.length {
            let metaEnd = nsText.range(of: "\n", range: NSRange(location: metaStart, length: nsText.length - metaStart))
            let length = (metaEnd.location == NSNotFound ? nsText.length : metaEnd.location) - metaStart
            string.addAttribute(.foregroundColor, value: TranscriptColors.secondary, range: NSRange(location: metaStart, length: length))
        }
        card.y += self.textSection(id, string, tool: tool, x: card.x, width: card.inner, maxHeight: .greatestFiniteMagnitude, into: &card)
    }
}
