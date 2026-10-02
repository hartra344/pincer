import Foundation

/// OpenClaw v2026.9.6's bounded, untrusted send-time reference envelope.
/// Location uses the established scalar selection field (newer detail fields are unnecessary).
public enum ChatWorkContext {
    private static let limits = ["page": 64, "title": 96, "sessionKey": 192, "sessionId": 64,
                                 "agentId": 64, "workspace": 224, "file": 224, "selection": 640]

    public static func isCommand(_ text: String) -> Bool {
        let first = text.drop(while: { $0.isWhitespace }).first
        return first == "/" || first == "!"
    }

    public static func location(_ snapshot: LocationContextSnapshot) -> JSONValue {
        ["page": "Pincer location", "selection": .string(snapshot.context)]
    }

    public static func validSnapshot(_ value: JSONValue?) -> Bool {
        guard let fields = value?.object, let page = fields["page"]?.string, !page.isEmpty else { return false }
        for (key, field) in fields {
            // Accept the newer official generic detail envelope when reading another client's history.
            if key == "detail" {
                guard let detail = field.object, detail.count <= 4,
                      detail.allSatisfy({ !$0.key.isEmpty && $0.key.utf16.count <= 32
                          && $0.value.string.map { $0.utf16.count <= 128 } == true }) else { return false }
            } else {
                guard let limit = Self.limits[key], let string = field.string, string.utf16.count <= limit else { return false }
            }
        }
        return true
    }

    /// Mirrors upstream projectChatWorkContextForDisplay. Only validated metadata proves alternate
    /// display text; authored paragraphs that resemble the model reference prefix remain untouched.
    /// Invoked at transcript decode, never by a row renderer.
    public static func projectForDisplay(_ message: JSONValue) -> JSONValue {
        guard message["role"]?.string == "user", var entry = message.object,
              var meta = entry["__openclaw"]?.object, let attached = meta["workContext"]?.object,
              Self.validSnapshot(attached["snapshot"]), let text = attached["text"]?.string else { return message }
        meta["workContext"] = ["snapshot": attached["snapshot"]!]
        entry["__openclaw"] = .object(meta)
        if let blocks = entry["content"]?.array {
            var seen = false
            var projected: [JSONValue] = []
            for block in blocks {
                guard ["text", "input_text"].contains(block["type"]?.string ?? "") else {
                    projected.append(block)
                    continue
                }
                guard !seen else { continue }
                seen = true
                var item = block.object ?? [:]
                item["text"] = .string(text)
                projected.append(.object(item))
            }
            if !seen, !text.isEmpty { projected.insert(["type": "text", "text": .string(text)], at: 0) }
            entry["content"] = .array(projected)
        } else if entry["content"]?.string != nil {
            entry["content"] = .string(text)
        } else if entry["text"]?.string != nil {
            entry["text"] = .string(text)
        }
        return .object(entry)
    }

    /// Only an explicit unknown-field schema rejection proves this optional field is unsupported.
    /// Auth, disconnects, malformed location values, and generic INVALID_REQUEST never lose context.
    public static func isUnsupported(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error, code == "INVALID_REQUEST" else { return false }
        let lower = message.lowercased()
        for kind in ["unexpected property", "unsupported property", "unknown property"] {
            if lower.contains("\(kind) 'workcontext'") || lower.contains("\(kind) \"workcontext\"") { return true }
        }
        return lower.contains("unsupported workcontext")
    }

    // Only the exact old Pincer signature, after a blank paragraph and anchored at end, is hidden.
    // Coordinates/accuracy/date are checked independently, and code examples are always left alone.
    private static let legacySuffix = try! NSRegularExpression(pattern:
        #"\n\nLocation context \(approximate, shared by Pincer\): 📍 (-?\d{1,3}\.\d{2}), (-?\d{1,3}\.\d{2}) ±(\d+)m; observed (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))\z"#)

    /// Bounded detection is safe on live interaction paths; full validation runs on a worker.
    public static func mayHaveLegacyFooter(_ text: String) -> Bool {
        text.suffix(256).contains("\n\nLocation context (approximate, shared by Pincer): 📍 ")
    }

    public static func legacyDisplayText(_ text: String) -> String {
        // The old generated footer is under 200 characters. Ordinary messages pay only a bounded
        // suffix scan, including long messages received through a live session.message event.
        let tail = String(text.suffix(256))
        guard tail.contains("\n\nLocation context (approximate, shared by Pincer): 📍 "),
              let match = Self.legacySuffix.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let suffix = Range(match.range, in: tail) else { return text }
        let suffixCount = tail.distance(from: suffix.lowerBound, to: tail.endIndex)
        guard text.count > suffixCount, !text.contains("```"), !text.contains("~~~") else { return text }
        func capture(_ index: Int) -> String? { Range(match.range(at: index), in: tail).map { String(tail[$0]) } }
        guard let lat = capture(1).flatMap(Double.init), (-90...90).contains(lat),
              let lon = capture(2).flatMap(Double.init), (-180...180).contains(lon),
              let accuracy = capture(3).flatMap(Int.init), (2_000...51_600).contains(accuracy),
              let observed = capture(4) else { return text }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = observed.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard formatter.date(from: observed) != nil else { return text }
        return String(text.dropLast(suffixCount))
    }
}

extension ChatItem {
    mutating func projectLegacyLocationForDisplay() {
        guard self.role == .user, self.sender == nil else { return }
        self.blocks = self.blocks.map { block in
            guard case let .text(text) = block else { return block }
            return .text(ChatWorkContext.legacyDisplayText(text))
        }
    }
}
