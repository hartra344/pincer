import Foundation
import NaturalLanguage

/// Splits a message into small pieces the Gateway can voice quickly (#562): two sentences per chunk all
/// the way through, so every chunk is made well before the one before it finishes playing. A sentence
/// longer than `limit` is cut at spaces.
public enum SpeechChunker {
    public static let sentencesPerChunk = 2
    public static let limit = 300

    public static func chunks(_ text: String, sentencesPerChunk: Int = Self.sentencesPerChunk,
                              limit: Int = Self.limit) -> [String]
    {
        let perChunk = max(1, sentencesPerChunk)
        let sentences = self.paragraphs(text).flatMap(self.sentences).flatMap { self.split($0, limit: max(1, limit)) }
        var result: [String] = []
        var current: [String] = []
        func flush() { if !current.isEmpty { result.append(current.joined(separator: " ")); current = [] } }
        for sentence in sentences {
            if !current.isEmpty, current.count >= perChunk || (current + [sentence]).joined(separator: " ").count > limit { flush() }
            current.append(sentence)
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
