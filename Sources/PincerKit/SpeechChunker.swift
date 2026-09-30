import Foundation
import NaturalLanguage

/// Splits a message into pieces the Gateway can voice within its timeout (#562). The first piece is the
/// first sentence or two so audio starts fast; the rest follow paragraphs, merged or split to fit `limit`.
public enum SpeechChunker {
    public static let firstLimit = 200
    public static let limit = 700

    public static func chunks(_ text: String, firstLimit: Int = Self.firstLimit, limit: Int = Self.limit) -> [String] {
        let firstLimit = max(1, min(firstLimit, limit))
        var paragraphs = self.paragraphs(text).map { self.sentences($0).flatMap { self.split($0, limit: limit) } }
        guard !paragraphs.isEmpty else { return [] }

        // First chunk: up to two sentences of the first paragraph that fit `firstLimit`.
        var opening = paragraphs[0]
        var first: [String] = []
        while let next = opening.first, first.count < 2 {
            if first.isEmpty, next.count > firstLimit {
                let parts = self.split(next, limit: firstLimit)
                first = [parts[0]]
                opening[0] = parts.dropFirst().joined(separator: " ")
                break
            }
            guard (first + [next]).joined(separator: " ").count <= firstLimit else { break }
            first.append(opening.removeFirst())
        }
        paragraphs[0] = opening.filter { !$0.isEmpty }
        var result = [first.joined(separator: " ")]

        var current = ""
        func flush() { if !current.isEmpty { result.append(current); current = "" } }
        for sentences in paragraphs where !sentences.isEmpty {
            let paragraph = sentences.joined(separator: " ")
            if paragraph.count <= limit {
                if current.isEmpty { current = paragraph }
                else if current.count + 2 + paragraph.count <= limit { current += "\n\n" + paragraph }
                else { flush(); current = paragraph }
                continue
            }
            flush()
            for sentence in sentences {
                if current.isEmpty { current = sentence }
                else if current.count + 1 + sentence.count <= limit { current += " " + sentence }
                else { flush(); current = sentence }
            }
            flush()
        }
        flush()
        return result
    }

    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func sentences(_ paragraph: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        var out: [String] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex ..< paragraph.endIndex) { range, _ in
            let s = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty ? [paragraph] : out
    }

    /// `sentence` in pieces of at most `limit` characters, cut at spaces where possible.
    static func split(_ sentence: String, limit: Int) -> [String] {
        var rest = Substring(sentence)
        var out: [String] = []
        while rest.count > limit {
            let head = rest.prefix(limit)
            let cut = head.lastIndex(where: { $0.isWhitespace }).flatMap { $0 > head.startIndex ? $0 : nil } ?? head.endIndex
            out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop(while: { $0.isWhitespace })
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}
