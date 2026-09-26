import Foundation
import PincerKit

/// Parsing markdown on every render made long transcripts stutter while scrolling.
@MainActor
enum MarkdownCache {
    private static var blockCache: [String: [MarkdownBlock]] = [:]
    private static var inlineCache: [String: AttributedString] = [:]

    static func blocks(_ source: String) -> [MarkdownBlock] {
        if let cached = self.blockCache[source] { return cached }
        let blocks = MarkdownBlock.parse(source)
        if self.blockCache.count > 1500 { self.blockCache.removeAll(keepingCapacity: true) }
        self.blockCache[source] = blocks
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        if let cached = self.inlineCache[text] { return cached }
        let parsed = MarkdownBlock.inline(text)
        if self.inlineCache.count > 6000 { self.inlineCache.removeAll(keepingCapacity: true) }
        self.inlineCache[text] = parsed
        return parsed
    }
}

