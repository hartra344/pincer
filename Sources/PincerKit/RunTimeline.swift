import Foundation

/// What a stretch of a run was spent on.
public enum RunSegmentKind: Hashable, Sendable {
    case thinking
    /// Streaming assistant text.
    case writing
    case tool(name: String)
    case compaction
    /// A point-in-time marker.
    case error(message: String)
    /// A point-in-time marker.
    case abort

    public var isMarker: Bool {
        switch self {
        case .error, .abort: true
        default: false
        }
    }
}

public struct RunSegment: Identifiable, Hashable, Sendable {
    /// Increases within a lane.
    public let id: Int
    public let kind: RunSegmentKind
    public let start: Date
    /// Nil while still going.
    public internal(set) var end: Date?
    public internal(set) var isError: Bool
    public let toolCallId: String?
    /// First line of the error, for errored tools and error markers.
    public internal(set) var detail: String?

    public var isOpen: Bool { self.end == nil && !self.kind.isMarker }

    public func duration(now: Date) -> TimeInterval {
        if self.kind.isMarker { return 0 }
        return max(0, (self.end ?? now).timeIntervalSince(self.start))
    }
}

public enum RunLaneStatus: String, Sendable, Hashable {
    case running, done, error, aborted
}

/// One run's activity, built from its streamed `agent` / `chat` events.
public struct RunLane: Identifiable, Hashable, Sendable {
    public let runId: String
    public var id: String { self.runId }
    public internal(set) var sessionKey: String?
    public internal(set) var startedAt: Date
    public internal(set) var endedAt: Date?
    /// Latest event seen for the run.
    public internal(set) var lastEventAt: Date
    public internal(set) var status: RunLaneStatus = .running
    public internal(set) var error: String?
    /// Oldest first; the oldest are dropped past the per-run cap.
    public internal(set) var segments: [RunSegment] = []
    public internal(set) var droppedSegments = 0
    public internal(set) var toolCount = 0
    public internal(set) var errorCount = 0

    var nextSegmentId = 0
    /// Highest `agent` event `seq` applied; the Gateway numbers each run's events in order.
    var lastSeq: Int?
    var openStreamId: Int?
    var openToolIds: [String: Int] = [:]
    var publishedEventAt: Date

    init(runId: String, sessionKey: String?, at date: Date) {
        self.runId = runId
        self.sessionKey = sessionKey
        self.startedAt = date
        self.lastEventAt = date
        self.publishedEventAt = date
    }

    public var isRunning: Bool { self.status == .running }

    public func duration(now: Date) -> TimeInterval {
        max(0, (self.endedAt ?? (self.isRunning ? now : self.lastEventAt)).timeIntervalSince(self.startedAt))
    }

    /// A caption for what the run is doing right now, e.g. "Running `web.search`…".
    public var currentActivity: String? {
        guard self.isRunning else { return nil }
        if let open = self.segments.last(where: \.isOpen) {
            switch open.kind {
            case let .tool(name): return "Running `\(name)`…"
            case .thinking: return "Thinking…"
            case .writing: return "Writing…"
            case .compaction: return "Compacting context…"
            case .error, .abort: break
            }
        }
        return "Working…"
    }

    private func position(of id: Int) -> Int? {
        guard let first = self.segments.first?.id, id >= first else { return nil }
        let index = id - first
        return index < self.segments.count && self.segments[index].id == id ? index : nil
    }

    mutating func append(_ kind: RunSegmentKind, at date: Date, toolCallId: String? = nil, detail: String? = nil,
                         cap: Int) -> Int
    {
        let id = self.nextSegmentId
        self.nextSegmentId += 1
        self.segments.append(RunSegment(id: id, kind: kind, start: date, end: kind.isMarker ? date : nil,
                                        isError: { if case .error = kind { true } else { false } }(), toolCallId: toolCallId, detail: detail))
        if self.segments.count > cap {
            // Drop a chunk at once so the shift is amortized.
            let drop = min(self.segments.count - cap + max(1, cap / 8), self.segments.count - 1)
            self.segments.removeFirst(drop)
            self.droppedSegments += drop
            let first = self.segments.first?.id ?? id
            if let open = self.openStreamId, open < first { self.openStreamId = nil }
            self.openToolIds = self.openToolIds.filter { $0.value >= first }
        }
        return id
    }

    mutating func closeStream(at date: Date) {
        guard let id = self.openStreamId else { return }
        self.openStreamId = nil
        if let index = self.position(of: id), self.segments[index].end == nil {
            self.segments[index].end = max(self.segments[index].start, date)
        }
    }

    mutating func closeAll(at date: Date) {
        self.closeStream(at: date)
        for (_, id) in self.openToolIds {
            if let index = self.position(of: id), self.segments[index].end == nil { self.segments[index].end = date }
        }
        self.openToolIds = [:]
        for index in self.segments.indices where self.segments[index].end == nil {
            self.segments[index].end = max(self.segments[index].start, date)
        }
    }

    mutating func finishTool(_ callId: String, at date: Date, isError: Bool, detail: String?) -> Bool {
        guard let id = self.openToolIds.removeValue(forKey: callId), let index = self.position(of: id) else { return false }
        self.segments[index].end = max(self.segments[index].start, date)
        self.segments[index].isError = isError
        if isError {
            self.segments[index].detail = detail
            self.errorCount += 1
        }
        return true
    }

    func openStreamKind() -> RunSegmentKind? {
        self.openStreamId.flatMap(self.position(of:)).map { self.segments[$0].kind }
    }
}

/// Per-run activity lanes for every run this client has seen streaming. A value-type reducer:
/// feed it `agent` and `chat` events in order. Bounded: at most `maxRuns` runs and
/// `maxSegmentsPerRun` segments per run, each event handled in O(1) amortized.
public struct RunTimeline: Sendable, Hashable {
    public static let defaultMaxRuns = 50
    public static let defaultMaxSegmentsPerRun = 500
    /// Streaming deltas that only move `lastEventAt` report a change at most this often.
    public static let coalesceInterval: TimeInterval = 1

    public let maxRuns: Int
    public let maxSegmentsPerRun: Int
    private var runs: [String: RunLane] = [:]
    /// Oldest first.
    public private(set) var runIds: [String] = []
    private var bySession: [String: [String]] = [:]

    public init(maxRuns: Int = defaultMaxRuns, maxSegmentsPerRun: Int = defaultMaxSegmentsPerRun) {
        self.maxRuns = max(1, maxRuns)
        self.maxSegmentsPerRun = max(2, maxSegmentsPerRun)
    }

    public var count: Int { self.runs.count }
    public func lane(_ runId: String) -> RunLane? { self.runs[runId] }

    /// Newest first.
    public func lanes(sessionKey: String) -> [RunLane] {
        (self.bySession[sessionKey] ?? []).reversed().compactMap { self.runs[$0] }
    }

    public func latestLane(sessionKey: String) -> RunLane? {
        self.bySession[sessionKey]?.last.flatMap { self.runs[$0] }
    }

    /// Latest event seen for any of the session's runs.
    public func lastEventAt(sessionKey: String) -> Date? {
        self.bySession[sessionKey]?.compactMap { self.runs[$0]?.lastEventAt }.max()
    }

    /// Handles `agent` and `chat` events; anything else is ignored. Returns whether the visible state changed.
    @discardableResult
    public mutating func apply(event: GatewayEvent, receivedAt: Date, sessionKey: String? = nil) -> Bool {
        switch event.name {
        case "agent": self.apply(agent: event.payload, receivedAt: receivedAt, sessionKey: sessionKey)
        case "chat": self.apply(chat: event.payload, receivedAt: receivedAt, sessionKey: sessionKey)
        default: false
        }
    }

    /// `agent` event: `{runId, seq, stream, ts, sessionKey?, data}`. `sessionKey` stands in when
    /// the payload doesn't carry one.
    @discardableResult
    public mutating func apply(agent payload: JSONValue, receivedAt: Date, sessionKey: String? = nil) -> Bool {
        guard let runId = payload["runId"]?.text, let stream = payload["stream"]?.string else { return false }
        let data = payload["data"] ?? .null
        let date = Self.date(payload["ts"]) ?? receivedAt
        let key = payload["sessionKey"]?.text ?? sessionKey
        let phase = data["phase"]?.string
        let isTerminal = stream == "lifecycle" && (phase == "end" || phase == "error")
        let cap = self.maxSegmentsPerRun
        guard var lane = self.take(runId, sessionKey: key, at: date, create: !isTerminal) else { return false }
        defer { self.put(lane) }
        // Replays (e.g. after a reconnect) repeat sequence numbers already applied.
        if let seq = payload["seq"]?.int {
            if let last = lane.lastSeq, seq <= last { return false }
            lane.lastSeq = seq
        }
        var changed = self.touch(&lane, at: date)

        switch stream {
        case "lifecycle":
            switch phase {
            case "start":
                if let started = Self.date(data["startedAt"]) { lane.startedAt = started }
                if lane.status != .running { lane.status = .running; lane.endedAt = nil }
                changed = true
            case "end", "error":
                let ended = Self.date(data["endedAt"]) ?? date
                if phase == "error" {
                    changed = self.finish(&lane, as: .error, at: ended,
                                          message: data["error"]?.text ?? "The run failed.") || changed
                } else if data["aborted"]?.bool == true {
                    changed = self.finish(&lane, as: .aborted, at: ended, message: nil) || changed
                } else {
                    changed = self.finish(&lane, as: .done, at: ended, message: nil) || changed
                }
            default:
                break
            }
        case "tool":
            guard let callId = data["toolCallId"]?.text else { break }
            if phase == "start", lane.isRunning, lane.openToolIds[callId] == nil {
                lane.closeStream(at: date)
                let id = lane.append(.tool(name: data["name"]?.text ?? "tool"), at: date, toolCallId: callId, cap: cap)
                lane.openToolIds[callId] = id
                lane.toolCount += 1
                changed = true
            } else if phase == "result" {
                let isError = data["isError"]?.bool ?? false
                let detail = isError ? Self.firstLine(data["error"]?.text ?? data["result"]?["error"]?.text
                    ?? data["result"]?.text) : nil
                changed = lane.finishTool(callId, at: date, isError: isError, detail: detail) || changed
            }
        case "thinking", "reasoning":
            changed = self.stream(.thinking, into: &lane, at: date) || changed
        case "assistant":
            changed = self.stream(.writing, into: &lane, at: date) || changed
        case "compaction":
            if phase == "start" {
                lane.closeStream(at: date)
                lane.openStreamId = lane.append(.compaction, at: date, cap: cap)
                changed = true
            } else if phase == "end", lane.openStreamKind() == .compaction {
                lane.closeStream(at: date)
                changed = true
            }
        case "error":
            let message = Self.firstLine(data["error"]?.text ?? data["message"]?.text ?? data["text"]?.text) ?? "Error"
            lane.closeStream(at: date)
            _ = lane.append(.error(message: message), at: date, detail: message, cap: cap)
            lane.errorCount += 1
            changed = true
        default:
            break
        }
        return changed
    }

    /// `chat` event: `{runId, sessionKey, state: delta | final | aborted | error, errorMessage?}`.
    @discardableResult
    public mutating func apply(chat payload: JSONValue, receivedAt: Date, sessionKey: String? = nil) -> Bool {
        guard let runId = payload["runId"]?.text else { return false }
        let state = payload["state"]?.string ?? ""
        let date = Self.date(payload["ts"]) ?? receivedAt
        let key = payload["sessionKey"]?.text ?? sessionKey
        let isTerminal = ["final", "aborted", "error"].contains(state)
        guard var lane = self.take(runId, sessionKey: key, at: date, create: !isTerminal) else { return false }
        defer { self.put(lane) }
        var changed = self.touch(&lane, at: date)
        switch state {
        case "final":
            changed = self.finish(&lane, as: .done, at: date, message: nil) || changed
        case "aborted":
            changed = self.finish(&lane, as: .aborted, at: date, message: nil) || changed
        case "error":
            changed = self.finish(&lane, as: .error, at: date,
                                  message: payload["errorMessage"]?.text ?? "The run failed.") || changed
        default:
            break
        }
        return changed
    }

    /// Settles runs whose end event never arrived (a dropped event, a reconnect): each of
    /// `sessionKey`'s running lanes that started at or before `asOf` (the session row's latest
    /// activity) ends at its last event with `status`. Rows older than a run say nothing about it,
    /// so a run that starts streaming before its row catches up is left alone. `.running` is a no-op.
    @discardableResult
    public mutating func settle(sessionKey: String, status: RunLaneStatus, asOf: Date) -> Bool {
        guard status != .running, let ids = self.bySession[sessionKey] else { return false }
        var changed = false
        for id in ids {
            guard var lane = self.runs[id], lane.isRunning, lane.startedAt <= asOf else { continue }
            changed = self.finish(&lane, as: status, at: lane.lastEventAt, message: nil) || changed
            self.runs[id] = lane
        }
        return changed
    }

    /// Sessions with a run still in progress here.
    public var runningSessionKeys: Set<String> {
        Set(self.runs.values.lazy.filter(\.isRunning).compactMap(\.sessionKey))
    }

    // MARK: Internals

    private mutating func take(_ runId: String, sessionKey: String?, at date: Date, create: Bool) -> RunLane? {
        if var lane = self.runs.removeValue(forKey: runId) {
            if lane.sessionKey == nil, let sessionKey {
                lane.sessionKey = sessionKey
                self.bySession[sessionKey, default: []].append(runId)
            }
            return lane
        }
        // A run first seen finishing has no activity worth a lane.
        guard create else { return nil }
        self.runIds.append(runId)
        if let sessionKey { self.bySession[sessionKey, default: []].append(runId) }
        return RunLane(runId: runId, sessionKey: sessionKey, at: date)
    }

    private mutating func put(_ lane: RunLane) {
        self.runs[lane.runId] = lane
        self.evictIfNeeded()
    }

    private mutating func evictIfNeeded() {
        while self.runs.count > self.maxRuns {
            let index = self.runIds.firstIndex { self.runs[$0]?.isRunning == false } ?? 0
            let runId = self.runIds.remove(at: index)
            if let key = self.runs.removeValue(forKey: runId)?.sessionKey {
                self.bySession[key]?.removeAll { $0 == runId }
                if self.bySession[key]?.isEmpty == true { self.bySession.removeValue(forKey: key) }
            }
        }
    }

    private func touch(_ lane: inout RunLane, at date: Date) -> Bool {
        // A finished run's last activity stays put, whatever straggles in after it.
        guard lane.isRunning, date > lane.lastEventAt else { return false }
        lane.lastEventAt = date
        guard date.timeIntervalSince(lane.publishedEventAt) >= Self.coalesceInterval else { return false }
        lane.publishedEventAt = date
        return true
    }

    private func stream(_ kind: RunSegmentKind, into lane: inout RunLane, at date: Date) -> Bool {
        guard lane.isRunning else { return false }
        if lane.openStreamKind() == kind { return false }
        lane.closeStream(at: date)
        lane.openStreamId = lane.append(kind, at: date, cap: self.maxSegmentsPerRun)
        return true
    }

    private func finish(_ lane: inout RunLane, as status: RunLaneStatus, at date: Date, message: String?) -> Bool {
        // `done` never overrides an abort or error already reported for the run.
        if !lane.isRunning, status == .done || lane.status == status { return false }
        let end = max(lane.startedAt, date)
        lane.closeAll(at: end)
        lane.status = status
        lane.endedAt = end
        switch status {
        case .aborted:
            _ = lane.append(.abort, at: end, cap: self.maxSegmentsPerRun)
        case .error:
            let line = Self.firstLine(message) ?? "The run failed."
            lane.error = line
            _ = lane.append(.error(message: line), at: end, detail: line, cap: self.maxSegmentsPerRun)
            lane.errorCount += 1
        case .done, .running:
            break
        }
        lane.publishedEventAt = max(lane.publishedEventAt, lane.lastEventAt)
        return true
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let ms = value?.double, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : String(line.prefix(200))
    }
}

// MARK: Rendering helpers

/// Durations the way the Runs panel shows them: `<1s`, `m:ss` under an hour, `h:mm:ss` above.
public enum RunDuration {
    public static func format(_ interval: TimeInterval) -> String {
        guard interval >= 1, let total = Int(saturating: interval, rounding: .towardZero) else { return "<1s" }
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0
            ? "\(hours):" + String(format: "%02d:%02d", minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// A segment placed on a lane `width` points wide. Tiny neighbours are merged so hundreds of
/// short steps don't turn into hundreds of hairline views.
public struct RunSpan: Identifiable, Hashable, Sendable {
    public let id: Int
    public let kind: RunSegmentKind
    public let start: Date
    public internal(set) var end: Date
    public internal(set) var isError: Bool
    public internal(set) var detail: String?
    /// How many segments this span stands for.
    public internal(set) var mergedCount: Int
    public let x: Double
    public internal(set) var width: Double

    public var isMarker: Bool { self.kind.isMarker }
}

extension RunLane {
    public func spans(axisStart: Date, axisEnd: Date, width: Double, now: Date, minWidth: Double = 3) -> [RunSpan] {
        let total = axisEnd.timeIntervalSince(axisStart)
        guard total > 0, width > 0 else { return [] }
        let scale = width / total
        var bars: [RunSpan] = []
        var markers: [RunSpan] = []
        for segment in self.segments {
            let end = segment.end ?? (self.isRunning ? now : self.lastEventAt)
            let x = max(0, min(width, segment.start.timeIntervalSince(axisStart) * scale))
            if segment.kind.isMarker {
                markers.append(RunSpan(id: segment.id, kind: segment.kind, start: segment.start, end: segment.start,
                                       isError: segment.isError, detail: segment.detail, mergedCount: 1, x: x, width: 0))
                continue
            }
            let w = max(0, min(width - x, end.timeIntervalSince(segment.start) * scale))
            if w < minWidth, var last = bars.last, last.width < minWidth * 2, x - (last.x + last.width) < minWidth {
                last.end = max(last.end, end)
                last.width = max(last.width, x + w - last.x)
                last.isError = last.isError || segment.isError
                if last.detail == nil { last.detail = segment.detail }
                last.mergedCount += 1
                bars[bars.count - 1] = last
            } else {
                bars.append(RunSpan(id: segment.id, kind: segment.kind, start: segment.start, end: end,
                                    isError: segment.isError, detail: segment.detail, mergedCount: 1,
                                    x: x, width: max(w, min(minWidth, width - x))))
            }
        }
        return bars + markers
    }
}
