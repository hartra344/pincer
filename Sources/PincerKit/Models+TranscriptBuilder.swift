import Foundation
import UniformTypeIdentifiers

// MARK: Presentation

/// A tool invocation paired with its result, rendered as one card.
public struct ToolActivity: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var arguments: String? { didSet { self.derive() } }
    public var result: String? { didSet { self.derive() } }
    /// `details` of the result, trimmed to what a file-edit diff reads. See `ToolFileEdit.parse`.
    public var details: JSONValue?
    public var isError: Bool
    public var isRunning: Bool
    /// One-line hint (command, path, query) for the collapsed card. Derived once, not per render.
    public private(set) var summary: String?
    /// Subagent session this call started, when the call names one.
    public private(set) var spawnedSessionKey: String?
    /// `label` argument of a spawn call, for matching the run when no key is echoed back.
    public private(set) var spawnLabel: String?

    public init(id: String, name: String, arguments: String?, result: String?, details: JSONValue? = nil,
                isError: Bool, isRunning: Bool)
    {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.details = details
        self.isError = isError
        self.isRunning = isRunning
        self.derive()
    }

    /// Scalar `details` keys other cards read: exec's exit status and web_fetch's response.
    public static let statusDetailKeys: Set<String> = ["exitCode", "exitSignal", "durationMs", "cwd", "status", "timedOut",
                                                       "failureKind", "tookMs", "finalUrl", "contentType", "title"]

    /// Keeps only the `details` keys the cards read (a file edit's diff; exec and web_fetch status
    /// scalars), so bulky details such as exec's `aggregated` output aren't held.
    public static func fileEditDetails(_ details: JSONValue?) -> JSONValue? {
        guard let object = details?.object else { return nil }
        let kept = object.filter { ["diff", "changed", "created"].contains($0.key)
            || Self.statusDetailKeys.contains($0.key) && $0.value.object == nil && $0.value.array == nil }
        return kept.isEmpty ? nil : .object(kept)
    }

    private mutating func derive() {
        let object = self.arguments?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let object, self.name == "ask_user", let questions = object["questions"] as? [[String: Any]] {
            self.summary = questions.lazy.compactMap { $0["question"] as? String }.first
        } else if let object {
            self.summary = ["command", "cmd", "path", "file_path", "url", "query", "pattern", "action"]
                .lazy.compactMap { object[$0] as? String }.first
        } else {
            self.summary = self.arguments.map { String($0.prefix(80)) }
        }
        self.spawnLabel = self.name.lowercased().contains("spawn") ? object?["label"] as? String : nil
        let text = [self.arguments, self.result].compactMap { $0 }.joined(separator: "\n")
        self.spawnedSessionKey = text.contains(":subagent:")
            ? text.firstMatch(of: /agent:[A-Za-z0-9_.-]+:subagent:[A-Za-z0-9-]+/).map { String($0.output) }
            : nil
    }
}

/// One visual row in the transcript. Assistant turns fold their thinking, tool calls
/// and tool results together, the way the OpenClaw native UI does.
public enum TranscriptEntry: Identifiable, Hashable, Sendable {
    case user(ChatItem)
    case assistant(AssistantTurn)
    case marker(id: String, label: String)

    public var id: String {
        switch self {
        case let .user(item): "u-\(item.id)"
        case let .assistant(turn): "a-\(turn.id)"
        case let .marker(id, _): "m-\(id)"
        }
    }
}

public struct AssistantTurn: Identifiable, Hashable, Sendable {
    public var id: String
    public var thinking: [String] = []
    public var tools: [ToolActivity] = []
    /// One entry per assistant message, so back-to-back messages in a turn stay distinct.
    public var text: [String] = []
    /// When each entry of `text` was sent, in the same order.
    public var textTimestamps: [Date?] = []
    /// Short name of the model that wrote each entry of `text`, when the Gateway recorded one.
    public var textModelNames: [String?] = []
    /// Transcript id of the message each entry of `text` came from, for replies and reactions.
    public var textIds: [String?] = []
    public var images: [ImageRef] = []
    public var files: [FileRef] = []
    public var timestamp: Date?
    public var isError = false
    public var isStreaming = false
    /// Model that generated the turn (the latest assistant message's, if a fallback switched
    /// models mid-turn). Comes from the Gateway's transcript, so it survives reloads and doesn't
    /// change when the session's model does. Nil when the Gateway didn't record one.
    public var model: String?
    public var provider: String?
    /// Who wrote the turn when it isn't this chat's agent: another agent, an automation or a helper.
    public var sender: MessageSender?

    public var body: String { self.text.joined(separator: "\n\n") }
    /// `provider/model`, e.g. `anthropic/claude-opus-4-8`.
    public var modelRef: String? { self.model.map { ModelRef.qualified($0, provider: self.provider) } }
    /// Short label for display, e.g. `claude-opus-4-8`.
    public var modelName: String? { self.modelRef.map(ModelRef.shortName) }
}

public enum TranscriptBuilder {
    public static func build(_ items: [ChatItem]) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var current: AssistantTurn?
        var currentRunId: String?
        var toolIndex: [String: Int] = [:]

        func flush() {
            if let turn = current {
                entries.append(.assistant(turn))
            }
            current = nil
            currentRunId = nil
            toolIndex.removeAll()
        }

        for item in items {
            switch item.role {
            case .user:
                flush()
                entries.append(.user(item))
            case .marker:
                flush()
                let label = switch item.markerKind {
                case "compaction": "Context compacted"
                case "reset": "New session"
                default: item.markerKind?.capitalized ?? "—"
                }
                entries.append(.marker(id: item.id, label: label))
            case .system:
                continue
            case .assistant:
                // A reply from another run (a cron job, a follow-up) is its own row, not part of this one.
                if let runId = item.runId, let currentRunId, runId != currentRunId { flush() }
                // So is a message from someone else: a new speaker always starts a new group.
                if let turn = current, turn.sender != item.sender { flush() }
                if let runId = item.runId { currentRunId = runId }
                var turn = current ?? AssistantTurn(id: item.id, timestamp: item.timestamp, sender: item.sender)
                turn.timestamp = item.timestamp ?? turn.timestamp
                turn.isError = turn.isError || item.isError
                if let model = item.model {
                    turn.model = model
                    turn.provider = item.provider
                }
                var message: [String] = []
                for block in item.blocks {
                    switch block {
                    case let .text(text):
                        let parsed = MediaDirectives.extract(from: text)
                        if !parsed.text.isEmpty { message.append(parsed.text) }
                        turn.images += parsed.images
                        turn.files += parsed.files
                    case let .thinking(text): turn.thinking.append(text)
                    case let .image(ref): turn.images.append(ref)
                    case let .file(file): turn.files.append(file)
                    case let .toolCall(id, name, arguments):
                        toolIndex[id] = turn.tools.count
                        turn.tools.append(ToolActivity(id: id, name: name, arguments: arguments, result: nil, isError: false, isRunning: false))
                    }
                }
                if !message.isEmpty {
                    turn.text.append(message.joined(separator: "\n\n"))
                    turn.textTimestamps.append(item.timestamp)
                    turn.textModelNames.append(item.modelRef.map(ModelRef.shortName))
                    turn.textIds.append(item.isReplyable ? item.transcriptId : nil)
                }
                current = turn
            case .toolResult:
                // Tool output belongs to the chat's agent, not to a forwarded message before it.
                if current?.sender != nil { flush() }
                var turn = current ?? AssistantTurn(id: item.id, timestamp: item.timestamp)
                let resultText = item.plainText
                if let callId = item.toolCallId, let index = toolIndex[callId] {
                    turn.tools[index].result = resultText
                    turn.tools[index].details = item.toolDetails
                    turn.tools[index].isError = item.isError
                } else {
                    turn.tools.append(ToolActivity(
                        id: item.toolCallId ?? item.id,
                        name: item.toolName ?? "tool",
                        arguments: nil,
                        result: resultText,
                        details: item.toolDetails,
                        isError: item.isError,
                        isRunning: false))
                }
                for block in item.blocks {
                    if case let .image(ref) = block { turn.images.append(ref) }
                }
                current = turn
            }
        }
        flush()
        return entries
    }
}

// MARK: Progress card

/// The agent's durable task checklist for a session (`progress_card` tool), read with
/// `progressCard.get` and invalidated by `progressCard.changed`. Older Gateways only stream it as
/// `agent` events on the `plan` stream.
public struct ProgressCard: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public struct Step: Sendable, Hashable {
        public var text: String
        public var status: Status

        public init(text: String, status: Status) {
            self.text = text
            self.status = status
        }
    }

    public var revision: Int
    public var updatedAt: Date?
    public var markdown: String?
    public var steps: [Step]

    public init(revision: Int, updatedAt: Date? = nil, markdown: String? = nil, steps: [Step]) {
        self.revision = revision
        self.updatedAt = updatedAt
        let trimmed = markdown.map(Self.strippingHTMLTags)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.markdown = trimmed?.isEmpty == false ? trimmed : nil
        self.steps = steps
    }

    /// The Gateway embeds raw HTML (e.g. an a11y `<progress>` element) that SwiftUI's Markdown
    /// can't render; the header already shows progress, so drop the tags.
    static func strippingHTMLTags(_ markdown: String) -> String {
        markdown.replacingOccurrences(
            of: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#, with: "", options: .regularExpression)
    }

    /// A `card` object from `progressCard.get`. Nil for `null` or a card with nothing to show.
    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        let steps = (json["steps"]?.array ?? []).compactMap(Self.step)
        self.init(
            revision: json["revision"]?.int ?? 0,
            updatedAt: json["updatedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) },
            markdown: json["markdown"]?.string,
            steps: steps)
        if self.markdown == nil, self.steps.isEmpty { return nil }
    }

    /// The `data` of a legacy `plan`-stream agent event (`phase: "update"`). Steps may be plain
    /// strings; only the first in-progress step is kept.
    public init?(legacyPlan data: JSONValue, revision: Int) {
        var sawInProgress = false
        let steps = (data["steps"]?.array ?? []).compactMap { raw -> Step? in
            let step: Step? = if let text = raw.string {
                Self.step(text: text, status: .pending)
            } else {
                Self.step(raw)
            }
            if step?.status == .inProgress {
                if sawInProgress { return nil }
                sawInProgress = true
            }
            return step
        }
        guard !steps.isEmpty else { return nil }
        self.init(revision: revision, updatedAt: Date(), markdown: data["explanation"]?.string, steps: steps)
    }

    private static func step(_ json: JSONValue) -> Step? {
        guard let text = json["step"]?.string, let status = json["status"]?.string.flatMap(Status.init) else {
            return nil
        }
        return self.step(text: text, status: status)
    }

    private static func step(text: String, status: Status) -> Step? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Step(text: trimmed, status: status)
    }

    public var completedCount: Int { self.steps.count { $0.status == .completed } }
    public var isComplete: Bool { !self.steps.isEmpty && self.completedCount == self.steps.count }

    /// The step being worked on, else the next pending one, else the last finished one.
    public var currentStep: Step? {
        self.steps.first { $0.status == .inProgress }
            ?? self.steps.first { $0.status == .pending }
            ?? self.steps.last
    }

    /// 1-based position of `currentStep`.
    public var currentPosition: Int {
        guard let current = self.currentStep, let index = self.steps.firstIndex(of: current) else { return 0 }
        return index + 1
    }

    /// First non-empty Markdown line without heading/list/quote markers, for the collapsed header.
    public var markdownSummary: String? {
        guard let line = self.markdown?.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let stripped = line.drop { $0.isWhitespace || "#-*>".contains($0) }
        let summary = stripped.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
        return summary.isEmpty ? nil : summary
    }
}
