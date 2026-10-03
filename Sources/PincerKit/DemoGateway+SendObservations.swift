#if DEBUG
import Foundation

/// Counts requests received by the demo, including schema-rejected attempts. Observations never
/// retain request JSON, authored text, quote text, credentials or attachment payloads.
package struct DemoSendRequestObservation: Sendable, Equatable {
    package let idempotencyKey: String
    package let hasReplyToID: Bool
    package let isQuotedFallback: Bool
}

extension DemoGateway {
    func trackSendRequests(matchingText nonce: String) {
        guard nonce.isContiguousUTF8, !nonce.isEmpty, nonce.utf8.prefix(129).count <= 128,
              self.sendObservations[nonce] != nil || self.sendObservations.count < 16 else { return }
        self.sendObservations[nonce] = []
    }

    func untrackSendRequests(matchingText nonce: String) { self.sendObservations[nonce] = nil }

    func observedSendRequests(matchingText nonce: String) -> [DemoSendRequestObservation] {
        self.sendObservations[nonce] ?? []
    }

    func observeSendRequest(_ params: JSONValue) {
        guard let message = params["message"]?.string else { return }
        for nonce in self.sendObservations.keys {
            guard var observations = self.sendObservations[nonce], observations.count < 4,
                  message == nonce || message.hasSuffix("\n\n" + nonce) else { continue }
            let suppliedKey = params["idempotencyKey"]?.string ?? ""
            let key = suppliedKey.isContiguousUTF8 && suppliedKey.utf8.prefix(129).count <= 128 ? suppliedKey : ""
            let hasReplyToID = params["replyToId"] != nil
            observations.append(DemoSendRequestObservation(
                idempotencyKey: key, hasReplyToID: hasReplyToID,
                isQuotedFallback: !hasReplyToID && message.hasPrefix("> ")))
            self.sendObservations[nonce] = observations
        }
    }
}
#endif
