/// The keyboard-selected message within an already laid-out transcript row. Only one row
/// and message identity are retained; changes inspect span IDs, never message text or layout.
package struct TranscriptMessagePartSelection: Sendable {
    package private(set) var rowID: String?
    package private(set) var messageID: String?

    package init() {}

    @discardableResult
    package mutating func reconcile(rowID: String?, messageIDs: [String]) -> String? {
        guard let rowID else {
            self.rowID = nil
            self.messageID = nil
            return nil
        }
        if self.rowID != rowID {
            self.rowID = rowID
            self.messageID = messageIDs.first
        } else if self.messageID.map({ messageIDs.contains($0) }) != true {
            self.messageID = messageIDs.first
        }
        return self.messageID
    }

    @discardableResult
    package mutating func move(forward: Bool, rowID: String, messageIDs: [String]) -> String? {
        guard let selected = self.reconcile(rowID: rowID, messageIDs: messageIDs),
              let index = messageIDs.firstIndex(of: selected) else { return nil }
        self.messageID = messageIDs[min(max(index + (forward ? 1 : -1), 0), messageIDs.count - 1)]
        return self.messageID
    }
}
