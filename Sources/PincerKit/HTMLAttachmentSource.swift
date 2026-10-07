import Foundation

/// Decodes an HTML/SVG attachment for the locked-down preview sheet. Runs off-main; rejects
/// oversized, binary, non-UTF-8 and blank files so the caller can show a failure instead.
package enum HTMLAttachmentSource {
    package static let maxBytes = 5 * 1024 * 1024

    package static func decode(_ data: Data) -> String? {
        guard data.count <= self.maxBytes, !data.prefix(8192).contains(0),
              let text = String(data: data, encoding: .utf8),
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
