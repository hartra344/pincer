import Foundation

/// One question inside an agent prompt (`ask_user`), as the Gateway normalized it.
public struct AgentQuestion: Identifiable, Hashable, Sendable {
    public struct Option: Hashable, Sendable {
        public let label: String
        public let description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public let questionId: String
    public let header: String
    public let question: String
    public let url: URL?
    public let options: [Option]
    public let multiSelect: Bool
    public let isOther: Bool
    public let isSecret: Bool
    /// The answer is saved to the Gateway's secret store rather than returned to the agent.
    public let secretStoreName: String?

    public var id: String { self.questionId }
    /// A free-text answer is allowed alongside (or instead of) the listed options.
    public var allowsFreeText: Bool { self.options.isEmpty || self.isOther }

    public init?(_ payload: JSONValue) {
        guard let questionId = payload["questionId"]?.string ?? payload["id"]?.string, !questionId.isEmpty,
              let question = payload["question"]?.string, !question.isEmpty
        else { return nil }
        self.questionId = questionId
        self.header = payload["header"]?.string ?? ""
        self.question = question
        self.url = payload["url"]?.string.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        self.options = (payload["options"]?.array ?? []).compactMap { option in
            guard let label = option["label"]?.string, !label.isEmpty else { return nil }
            return Option(label: label, description: option["description"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        }
        self.multiSelect = payload["multiSelect"]?.bool ?? false
        self.isOther = payload["isOther"]?.bool ?? false
        self.isSecret = payload["isSecret"]?.bool ?? false
        self.secretStoreName = payload["secretStore"]?["name"]?.string
    }
}

/// A pending `question.requested` record: up to three questions the agent is blocked on.
public struct QuestionPrompt: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable {
        case pending, answered, cancelled, expired
    }

    public let id: String
    public let questions: [AgentQuestion]
    public let agentId: String?
    public let sessionKey: String?
    public let runId: String?
    public let createdAt: Date?
    public let expiresAt: Date?
    public let status: Status

    public init?(_ payload: JSONValue) {
        let record = payload["question"]?["questions"] != nil ? payload["question"]! : payload
        guard let id = record["id"]?.text else { return nil }
        let questions = (record["questions"]?.array ?? []).compactMap(AgentQuestion.init)
        guard !questions.isEmpty else { return nil }
        self.id = id
        self.questions = questions
        self.agentId = record["agentId"]?.text
        self.sessionKey = record["sessionKey"]?.text
        self.runId = record["runId"]?.text
        self.createdAt = record["createdAtMs"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.expiresAt = record["expiresAtMs"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.status = record["status"]?.string.flatMap(Status.init(rawValue:)) ?? .pending
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        self.status == .expired || (self.expiresAt.map { date >= $0 } ?? false)
    }

    public func isAnswerable(at date: Date = Date()) -> Bool {
        self.status == .pending && !self.isExpired(at: date)
    }

    /// Whether this prompt belongs in the chat for `sessionKey`. Prompts without a session show everywhere.
    public func belongs(to sessionKey: String?) -> Bool {
        guard let mine = self.sessionKey, let sessionKey else { return true }
        return mine.caseInsensitiveCompare(sessionKey) == .orderedSame
    }
}

/// What the user has picked or typed for one prompt, and the `question.resolve` answers it makes.
/// Mirrors the official clients: option labels in option order, then trimmed free text.
public struct QuestionDraft: Equatable, Sendable {
    public private(set) var selected: [String: Set<String>] = [:]
    public private(set) var otherText: [String: String] = [:]

    public init() {}

    public func isSelected(_ label: String, in question: AgentQuestion) -> Bool {
        self.selected[question.questionId]?.contains(label) == true
    }

    public func text(for question: AgentQuestion) -> String {
        self.otherText[question.questionId] ?? ""
    }

    public mutating func toggle(_ label: String, in question: AgentQuestion) {
        guard question.options.contains(where: { $0.label == label }) else { return }
        var picked = self.selected[question.questionId] ?? []
        if question.multiSelect {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            picked = picked == [label] ? [] : [label]
            // A single answer is either an option or free text, not both.
            if !picked.isEmpty { self.otherText[question.questionId] = "" }
        }
        self.selected[question.questionId] = picked
    }

    /// Picks the 1-based option number, as the number keys do. Returns false when there's no such option.
    @discardableResult
    public mutating func toggle(number: Int, in question: AgentQuestion) -> Bool {
        guard question.options.indices.contains(number - 1) else { return false }
        self.toggle(question.options[number - 1].label, in: question)
        return true
    }

    public mutating func setText(_ value: String, for question: AgentQuestion) {
        guard question.allowsFreeText else { return }
        self.otherText[question.questionId] = value
        if !question.multiSelect, !Self.freeText(value, secret: question.isSecret).isEmpty {
            self.selected[question.questionId] = []
        }
    }

    /// The values for one question, or nil when it has no answer yet.
    public func values(for question: AgentQuestion) -> [String]? {
        let picked = self.selected[question.questionId] ?? []
        var values = question.options.map(\.label).filter { picked.contains($0) }
        let other = Self.freeText(self.otherText[question.questionId] ?? "", secret: question.isSecret)
        if !other.isEmpty { values.append(other) }
        return values.isEmpty ? nil : values
    }

    /// `answers` for `question.resolve`, or nil until every question has an answer.
    public func answers(for prompt: QuestionPrompt) -> [String: [String]]? {
        var result: [String: [String]] = [:]
        for question in prompt.questions {
            guard let values = self.values(for: question) else { return nil }
            result[question.questionId] = values
        }
        return result
    }

    /// Secrets are sent exactly as typed; everything else is trimmed.
    private static func freeText(_ value: String, secret: Bool) -> String {
        secret ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
