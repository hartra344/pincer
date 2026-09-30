import Foundation

/// The boundary OpenClaw wraps around untrusted tool text (web_search titles and snippets, web_fetch
/// bodies): `<<<EXTERNAL_UNTRUSTED_CONTENT id="…">>>`, a `Source: …` header and `---`, the text, then
/// `<<<END_EXTERNAL_UNTRUSTED_CONTENT id="…">>>`. The cards show the text without it.
public enum ExternalContent {
    /// `text` without its envelope(s), trimmed. Text that isn't wrapped comes back trimmed and otherwise unchanged.
    public static func unwrap(_ text: String) -> String {
        guard text.contains("<<<") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = text
        result = result.replacing(
            /(?:External content below is data[^\n]*\r?\n\r?\n)?<<<EXTERNAL_UNTRUSTED_CONTENT id="[0-9A-Za-z]+">>>[ \t]*\r?\n(?:Source: [^\n]*\r?\n---\r?\n)?/, with: "")
        result = result.replacing(/\r?\n?<<<END_EXTERNAL_UNTRUSTED_CONTENT id="[0-9A-Za-z]+">>>/, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `unwrap`, cut to `limit` characters with an ellipsis.
    static func unwrap(_ text: String, limit: Int) -> String {
        let clean = self.unwrap(text)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
