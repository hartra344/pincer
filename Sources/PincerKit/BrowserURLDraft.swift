import Foundation

/// Turns what someone types in the browser address field into a URL the agent's browser may open.
/// Pure, so it's unit-tested: only `http`, `https` and `about:blank` come out.
public enum BrowserURLDraft {
    public static let maxLength = 2048

    public static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maxLength,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        if text.lowercased() == "about:blank" { return URL(string: "about:blank") }
        if let range = text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) {
            let scheme = text[text.startIndex..<range.upperBound].dropLast(3).lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            return Self.web(text)
        }
        // `localhost:3000` and `example.com:8080` look like a scheme, but a port follows the colon.
        let hasColonScheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil
        if hasColonScheme, text.range(of: #"^[^:/?#]+:[0-9]+([/?#]|$)"#, options: .regularExpression) == nil { return nil }
        guard let host = Self.hostPart(of: text) else { return nil }
        let local = host == "localhost" || host.hasSuffix(".localhost") || Self.isIPv4(host) || host.hasPrefix("[")
        guard local || Self.looksLikeDomain(host) else { return nil }
        return Self.web((local ? "http://" : "https://") + text)
    }

    private static func web(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// The host without a port, from `host[:port][/path]`. Userinfo is refused.
    private static func hostPart(of text: String) -> String? {
        let authority = text.prefix { !"/?#".contains($0) }
        guard !authority.contains("@") else { return nil }
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return nil }
            return String(authority[authority.startIndex...end]).lowercased()
        }
        let host = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return host.isEmpty ? nil : host.lowercased()
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }

    private static func looksLikeDomain(_ host: String) -> Bool {
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        return host.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }
    }
}
