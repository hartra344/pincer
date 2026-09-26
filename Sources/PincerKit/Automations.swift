import Foundation
import Observation

// Cron jobs ("automations") through the Gateway's `cron.*` methods.

/// When a cron job runs.
public enum CronSchedule: Equatable, Sendable {
    /// A fixed interval.
    case every(ms: Int, anchorMs: Int?)
    /// A five-field cron expression, optionally in a time zone.
    case cron(expr: String, tz: String?)
    /// Once, at an ISO 8601 time.
    case at(String)
    /// Event-driven kinds (`on-exit`, `stream`, …) this app shows but doesn't edit.
    case other(kind: String, raw: JSONValue)

    public init(_ json: JSONValue?) {
        let kind = json?["kind"]?.text ?? ""
        switch kind {
        case "every" where json?["everyMs"]?.int != nil:
            self = .every(ms: json?["everyMs"]?.int ?? 0, anchorMs: json?["anchorMs"]?.int)
        case "cron" where json?["expr"]?.text != nil:
            self = .cron(expr: json?["expr"]?.text ?? "", tz: json?["tz"]?.text)
        case "at" where json?["at"]?.text != nil:
            self = .at(json?["at"]?.text ?? "")
        default:
            self = .other(kind: kind, raw: json ?? .null)
        }
    }

    public var json: JSONValue {
        switch self {
        case let .every(ms, anchorMs):
            var object: [String: JSONValue] = ["kind": "every", "everyMs": JSONValue(ms)]
            if let anchorMs { object["anchorMs"] = JSONValue(anchorMs) }
            return .object(object)
        case let .cron(expr, tz):
            var object: [String: JSONValue] = ["kind": "cron", "expr": .string(expr)]
            if let tz { object["tz"] = .string(tz) }
            return .object(object)
        case let .at(at):
            return ["kind": "at", "at": .string(at)]
        case let .other(_, raw):
            return raw
        }
    }

    public var isEditable: Bool {
        if case .other = self { return false }
        return true
    }

    public var summary: String {
        switch self {
        case let .every(ms, _):
            return "Every \(Self.interval(ms))"
        case let .cron(expr, tz):
            return tz.map { "\(expr) (\($0))" } ?? expr
        case let .at(at):
            guard let date = Self.date(fromISO: at) else { return "Once at \(at)" }
            return "Once, \(date.formatted(date: .abbreviated, time: .shortened))"
        case let .other(kind, _):
            switch kind {
            case "on-exit": return "When a command exits"
            case "stream": return "On command output"
            case "": return "Custom schedule"
            default: return kind.capitalized
            }
        }
    }

    /// "15 minutes", "hour", "2 days"…
    static func interval(_ ms: Int) -> String {
        let units: [(ms: Int, name: String)] = [(86_400_000, "day"), (3_600_000, "hour"), (60_000, "minute"), (1000, "second")]
        guard let unit = units.first(where: { ms >= $0.ms && ms % $0.ms == 0 }) else { return "\(ms) ms" }
        let count = ms / unit.ms
        return count == 1 ? unit.name : "\(count) \(unit.name)s"
    }

    static func date(fromISO text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// How a run (or a job's last run) ended.
public enum CronRunOutcome: String, Sendable {
    case ok, error, skipped
}

/// One cron job from `cron.list` / `cron.get`.
public struct CronJob: Identifiable, Equatable, Sendable {
    public enum Health: Equatable, Sendable {
        case paused, running, failing, ok, skipped, idle
    }

    public let id: String
    public let name: String
    public let description: String?
    public let agentId: String?
    public let enabled: Bool
    public let schedule: CronSchedule
    /// `isolated`, `main`, `current` or `session:<key>`.
    public let sessionTarget: String
    /// `agentTurn`, `systemEvent`, `command`, `script`, `heartbeat`…
    public let payloadKind: String
    /// The agent turn's message or the system event's text.
    public let payloadText: String?
    public let deliveryMode: String?
    public let deliveryTarget: String?
    public let configRevision: String?
    public let nextRunAt: Date?
    public let lastRunAt: Date?
    public let runningSince: Date?
    public let lastStatus: CronRunOutcome?
    public let lastError: String?
    public let lastDurationMs: Int?
    public let consecutiveErrors: Int
    public let raw: JSONValue

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text ?? json["jobId"]?.text else { return nil }
        let state = json["state"]
        func field(_ key: String) -> JSONValue? { state?[key] ?? json[key] }
        func date(_ key: String) -> Date? { field(key)?.double.map { Date(timeIntervalSince1970: $0 / 1000) } }
        self.id = id
        self.name = json["displayName"]?.text ?? json["name"]?.text ?? id
        self.description = json["description"]?.text
        self.agentId = json["agentId"]?.text
        self.enabled = json["enabled"]?.bool ?? true
        self.schedule = CronSchedule(json["schedule"])
        self.sessionTarget = json["sessionTarget"]?.text ?? "isolated"
        let payload = json["payload"]
        self.payloadKind = payload?["kind"]?.text ?? "agentTurn"
        self.payloadText = payload?["message"]?.text ?? payload?["text"]?.text
        let delivery = json["delivery"]
        self.deliveryMode = delivery?["mode"]?.text
        self.deliveryTarget = [delivery?["channel"]?.text, delivery?["to"]?.text].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        self.configRevision = json["configRevision"]?.text
        self.nextRunAt = date("nextRunAtMs")
        self.lastRunAt = date("lastRunAtMs")
        self.runningSince = date("runningAtMs")
        self.lastStatus = (field("lastRunStatus") ?? field("lastStatus"))?.text.flatMap(CronRunOutcome.init)
        self.lastError = field("lastError")?.text ?? json["lastRunError"]?.text
        self.lastDurationMs = field("lastDurationMs")?.int
        self.consecutiveErrors = field("consecutiveErrors")?.int ?? 0
        self.raw = json
    }

    public var health: Health {
        if self.runningSince != nil { return .running }
        if !self.enabled { return .paused }
        switch self.lastStatus {
        case .error: return .failing
        case .ok: return .ok
        case .skipped: return .skipped
        case nil: return .idle
        }
    }

    /// The automation's chat in the sidebar (`agent:<agent>:cron:<job>`).
    public func chatKey(defaultAgentId: String) -> String {
        "agent:\(self.agentId ?? defaultAgentId):cron:\(self.id)"
    }

    /// Whether the editor can change what the job does (not just its name and schedule).
    public var isTaskEditable: Bool {
        (self.payloadKind == "agentTurn" && self.sessionTarget == "isolated")
            || (self.payloadKind == "systemEvent" && self.sessionTarget == "main")
    }
}

/// One entry of `cron.runs`.
public struct CronRun: Identifiable, Equatable, Sendable {
    public let id: String
    public let jobId: String
    public let jobName: String?
    /// When the run started (`runAtMs`), or when it was logged.
    public let startedAt: Date
    public let status: CronRunOutcome?
    public let error: String?
    public let summary: String?
    public let durationMs: Int?
    /// The chat the run happened in, when the Gateway recorded one.
    public let sessionKey: String?
    public let model: String?
    public let deliveryStatus: String?

    public init?(_ json: JSONValue) {
        guard let jobId = json["jobId"]?.text, let ts = json["ts"]?.double else { return nil }
        let started = json["runAtMs"]?.double ?? ts
        self.id = json["runId"]?.text ?? "\(jobId)@\(Int(ts))"
        self.jobId = jobId
        self.jobName = json["jobName"]?.text
        self.startedAt = Date(timeIntervalSince1970: started / 1000)
        self.status = json["status"]?.text.flatMap(CronRunOutcome.init)
        self.error = json["error"]?.text
        self.summary = json["summary"]?.text
        self.durationMs = json["durationMs"]?.int
        self.sessionKey = json["sessionKey"]?.text
        self.model = json["model"]?.text
        self.deliveryStatus = json["deliveryStatus"]?.text
    }
}

/// `cron.status`.
public struct CronSchedulerStatus: Equatable, Sendable {
    public let enabled: Bool
    public let jobCount: Int?
    public let nextWakeAt: Date?

    public init(_ json: JSONValue) {
        self.enabled = json["enabled"]?.bool ?? true
        self.jobCount = json["jobs"]?.int
        self.nextWakeAt = json["nextWakeAtMs"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// The editor's copy of a job: new, or an existing one. Saving an existing job sends only what
/// changed, so fields the editor doesn't show (delivery targets, models, failure alerts…) are kept.
public struct CronJobDraft: Equatable, Identifiable, Sendable {
    public enum ScheduleKind: String, CaseIterable, Identifiable, Sendable {
        case every, cron, at
        public var id: String { self.rawValue }
        public var label: String {
            switch self {
            case .every: "Repeat"
            case .cron: "Cron"
            case .at: "Once"
            }
        }
    }

    public enum Unit: String, CaseIterable, Identifiable, Sendable {
        case minutes, hours, days
        public var id: String { self.rawValue }
        public var label: String { self.rawValue.capitalized }
        var ms: Int {
            switch self {
            case .minutes: 60_000
            case .hours: 3_600_000
            case .days: 86_400_000
            }
        }
    }

    /// Where the job runs: an agent turn in its own session, or a system event in the main chat.
    public enum Target: String, CaseIterable, Identifiable, Sendable {
        case isolated, main
        public var id: String { self.rawValue }
        public var label: String {
            switch self {
            case .isolated: "Its own chat"
            case .main: "The agent's main chat"
            }
        }
    }

    public var name = ""
    public var description = ""
    public var agentId: String
    public var enabled = true
    public var scheduleKind = ScheduleKind.every
    public var everyAmount = 30
    public var everyUnit = Unit.minutes
    public var cronExpr = "0 7 * * *"
    public var timeZone = ""
    public var runAt = Date().addingTimeInterval(3600)
    public var target = Target.isolated
    public var message = ""
    /// Isolated runs: post the result to the last channel the agent used.
    public var announce = false

    /// The job being edited; nil for a new one.
    public let original: CronJob?
    /// The draft as it was loaded, to tell what changed.
    private var initial: CronJobDraft.Fields?

    private struct Fields: Equatable, Sendable {
        let name, description, agentId: String
        let enabled: Bool
        let schedule: JSONValue?
        let target: Target
        let message: String
        let announce: Bool
    }

    public init(agentId: String) {
        self.agentId = agentId
        self.original = nil
    }

    public init(job: CronJob, defaultAgentId: String) {
        self.original = job
        self.name = job.name
        self.description = job.description ?? ""
        self.agentId = job.agentId ?? defaultAgentId
        self.enabled = job.enabled
        switch job.schedule {
        case let .every(ms, _):
            self.scheduleKind = .every
            let unit = Unit.allCases.reversed().first { ms % $0.ms == 0 } ?? .minutes
            self.everyUnit = unit
            self.everyAmount = max(1, ms / unit.ms)
        case let .cron(expr, tz):
            self.scheduleKind = .cron
            self.cronExpr = expr
            self.timeZone = tz ?? ""
        case let .at(at):
            self.scheduleKind = .at
            self.runAt = CronSchedule.date(fromISO: at) ?? self.runAt
        case .other:
            break
        }
        self.target = job.sessionTarget == "main" ? .main : .isolated
        self.message = job.payloadText ?? ""
        self.announce = job.deliveryMode == "announce"
        self.initial = self.fields
    }

    public var id: String { self.original?.id ?? AutomationsModel.newJobKey }
    public var isNew: Bool { self.original == nil }
    public var isScheduleEditable: Bool { self.original?.schedule.isEditable ?? true }
    public var isTaskEditable: Bool { self.original?.isTaskEditable ?? true }

    public var schedule: CronSchedule? {
        guard self.isScheduleEditable else { return nil }
        switch self.scheduleKind {
        case .every:
            return .every(ms: self.everyAmount * self.everyUnit.ms, anchorMs: nil)
        case .cron:
            return .cron(expr: self.cronExpr.trimmingCharacters(in: .whitespacesAndNewlines), tz: self.timeZone.nilIfEmpty)
        case .at:
            let formatter = ISO8601DateFormatter()
            return .at(formatter.string(from: self.runAt))
        }
    }

    private var fields: Fields {
        Fields(name: self.name.trimmingCharacters(in: .whitespacesAndNewlines),
               description: self.description.trimmingCharacters(in: .whitespacesAndNewlines),
               agentId: self.agentId, enabled: self.enabled, schedule: self.schedule?.json, target: self.target,
               message: self.message.trimmingCharacters(in: .whitespacesAndNewlines), announce: self.announce)
    }

    public var hasChanges: Bool { self.initial.map { $0 != self.fields } ?? true }

    /// Why the draft can't be saved yet.
    public var problem: String? {
        let fields = self.fields
        if fields.name.isEmpty { return "Give the automation a name." }
        if self.isScheduleEditable {
            switch self.scheduleKind {
            case .every where self.everyAmount < 1:
                return "The interval must be at least 1."
            case .cron where !(5...6).contains(self.cronExpr.split(whereSeparator: \.isWhitespace).count):
                return "A cron expression has five fields: minute, hour, day of month, month and day of week."
            case .at where self.isNew && self.runAt < Date():
                return "Pick a time in the future."
            default:
                break
            }
        }
        if self.isTaskEditable, fields.message.isEmpty {
            return self.target == .main ? "Write the event text for the main chat." : "Write what the agent should do."
        }
        return nil
    }

    private var payload: JSONValue {
        let message = JSONValue.string(self.fields.message)
        return self.target == .main ? ["kind": "systemEvent", "text": message] : ["kind": "agentTurn", "message": message]
    }

    private var delivery: JSONValue {
        self.announce ? ["mode": "announce", "channel": "last"] : ["mode": "none"]
    }

    /// `cron.add` params for a new job.
    public var addParams: JSONValue {
        let fields = self.fields
        var params: [String: JSONValue] = [
            "name": .string(fields.name),
            "agentId": .string(fields.agentId),
            "enabled": .bool(fields.enabled),
            "schedule": fields.schedule ?? .null,
            "sessionTarget": .string(self.target.rawValue),
            "wakeMode": "now",
            "payload": self.payload,
        ]
        if !fields.description.isEmpty { params["description"] = .string(fields.description) }
        if self.target == .isolated { params["delivery"] = self.delivery }
        if self.scheduleKind == .at { params["deleteAfterRun"] = false }
        return .object(params)
    }

    /// The `cron.update` patch: only the fields that changed.
    public var patch: [String: JSONValue] {
        guard let initial = self.initial else { return self.addParams.object ?? [:] }
        let fields = self.fields
        var patch: [String: JSONValue] = [:]
        if fields.name != initial.name { patch["name"] = .string(fields.name) }
        if fields.description != initial.description { patch["description"] = .string(fields.description) }
        if fields.agentId != initial.agentId { patch["agentId"] = .string(fields.agentId) }
        if fields.enabled != initial.enabled { patch["enabled"] = .bool(fields.enabled) }
        if fields.schedule != initial.schedule, let schedule = fields.schedule { patch["schedule"] = schedule }
        if self.isTaskEditable {
            if fields.target != initial.target {
                patch["sessionTarget"] = .string(self.target.rawValue)
                patch["payload"] = self.payload
            } else if fields.message != initial.message {
                patch["payload"] = self.payload
            }
            if self.target == .isolated, fields.announce != initial.announce || fields.target != initial.target {
                patch["delivery"] = self.delivery
            }
        }
        return patch
    }
}

/// The Automations view's data for one Gateway: jobs, the scheduler, and each job's run history.
@MainActor
@Observable
public final class AutomationsModel {
    public private(set) var jobs: [CronJob] = []
    public private(set) var scheduler: CronSchedulerStatus?
    /// False when the Gateway has no `cron.*` methods.
    public private(set) var supported = true
    public private(set) var hasLoaded = false
    public private(set) var loadState = OperationState.idle
    public private(set) var runs: [String: [CronRun]] = [:]
    public private(set) var runsState: [String: OperationState] = [:]
    /// Actions in flight or failed, by job id.
    public private(set) var operations: [String: OperationState] = [:]

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let hello: () -> GatewayHello?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public static let pageSize = 200
    public static let runsLimit = 50

    init(connection: GatewayConnection, hello: @escaping () -> GatewayHello?) {
        self.connection = connection
        self.hello = hello
    }

    /// Writes (`cron.add`, `.update`, `.remove`, `.run`) need `operator.admin`, like Gateway Settings.
    public var canEdit: Bool { self.hello()?.scopes.contains(GatewayConnection.adminScope) ?? false }

    public func job(_ id: String?) -> CronJob? { self.jobs.first { $0.id == id } }
    public func operation(for jobId: String) -> OperationState { self.operations[jobId] ?? .idle }

    // MARK: Loading

    public func load() async {
        guard !self.loadState.isRunning else { return }
        // Gateways list their methods in `hello`; skip the round trip when cron isn't there.
        if let methods = self.hello()?.methods, !methods.isEmpty, !methods.contains("cron.list") {
            self.supported = false
            self.hasLoaded = true
            return
        }
        self.loadState = .running
        async let status = try? self.connection.request("cron.status", [:])
        do {
            self.jobs = try await self.fetchJobs()
            self.supported = true
            self.loadState = .idle
        } catch let error where Self.isUnknownMethod(error) {
            self.supported = false
            self.loadState = .idle
        } catch {
            self.loadState = .failed(Self.message(for: error))
        }
        if let status = await status { self.scheduler = CronSchedulerStatus(status) }
        self.hasLoaded = true
    }

    private func fetchJobs() async throws -> [CronJob] {
        var jobs: [CronJob] = []
        var offset = 0
        for _ in 0..<20 {
            let params: JSONValue = ["includeDisabled": true, "limit": JSONValue(Self.pageSize), "offset": JSONValue(offset),
                                     "sortBy": "nextRunAtMs", "sortDir": "asc"]
            let result = try await self.connection.request("cron.list", params, timeout: 30)
            let page = (result["jobs"]?.array ?? result.array ?? []).compactMap(CronJob.init)
            jobs += page
            guard result["hasMore"]?.bool == true, let next = result["nextOffset"]?.int, next > offset, !page.isEmpty
            else { break }
            offset = next
        }
        return Self.sorted(jobs)
    }

    /// Enabled jobs by next run, then paused ones by name.
    static func sorted(_ jobs: [CronJob]) -> [CronJob] {
        jobs.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            switch (lhs.nextRunAt, rhs.nextRunAt) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    public func loadRuns(for jobId: String) async {
        guard self.supported, self.runsState[jobId]?.isRunning != true else { return }
        self.runsState[jobId] = .running
        do {
            let params: JSONValue = ["scope": "job", "id": .string(jobId), "limit": JSONValue(Self.runsLimit), "sortDir": "desc"]
            let result = try await self.connection.request("cron.runs", params, timeout: 30)
            let entries = (result["entries"]?.array ?? result["runs"]?.array ?? []).compactMap(CronRun.init)
            self.runs[jobId] = entries.sorted { $0.startedAt > $1.startedAt }
            self.runsState[jobId] = .idle
        } catch {
            self.runsState[jobId] = .failed(Self.message(for: error))
        }
    }

    /// `cron.get`: refreshes one job in place.
    public func refresh(_ jobId: String) async {
        guard let result = try? await self.connection.request("cron.get", ["id": .string(jobId)]) else { return }
        self.replace(CronJob(result["job"] ?? result))
    }

    private func replace(_ job: CronJob?) {
        guard let job else { return }
        if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
            self.jobs[index] = job
        } else {
            self.jobs.append(job)
        }
        self.jobs = Self.sorted(self.jobs)
    }

    /// The Gateway's `cron` event: something about a job changed, started or finished.
    func handleCronEvent(_ payload: JSONValue) {
        guard self.hasLoaded, self.supported else { return }
        let jobId = payload["jobId"]?.text ?? payload["id"]?.text
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.load()
            if let jobId, self.runs[jobId] != nil { await self.loadRuns(for: jobId) }
        }
    }

    // MARK: Actions

    /// Runs the job now, even if it's paused or not due.
    @discardableResult
    public func runNow(_ job: CronJob) async -> Bool {
        await self.perform(job.id, "cron.run", ["id": .string(job.id), "mode": "force"]) { _ in
            await self.refresh(job.id)
            await self.loadRuns(for: job.id)
        }
    }

    @discardableResult
    public func setEnabled(_ job: CronJob, _ enabled: Bool) async -> Bool {
        await self.update(job, patch: ["enabled": .bool(enabled)])
    }

    /// Creates the draft's job, or saves its changes. Returns the job's id.
    public func save(_ draft: CronJobDraft) async -> String? {
        guard let original = draft.original else {
            var created: String?
            _ = await self.perform(Self.newJobKey, "cron.add", draft.addParams) { result in
                let job = CronJob(result["job"] ?? result)
                created = job?.id
                self.replace(job)
            }
            return created
        }
        let patch = draft.patch
        guard !patch.isEmpty else { return original.id }
        return await self.update(original, patch: patch) ? original.id : nil
    }

    private func update(_ job: CronJob, patch: [String: JSONValue]) async -> Bool {
        var params: [String: JSONValue] = ["id": .string(job.id), "patch": .object(patch)]
        if let revision = job.configRevision { params["expectedConfigRevision"] = .string(revision) }
        let ok = await self.perform(job.id, "cron.update", .object(params)) { result in
            if let updated = CronJob(result["job"] ?? result) { self.replace(updated) } else { await self.refresh(job.id) }
        }
        // Someone else changed it: show the latest version so the next try works on it.
        if !ok { await self.refresh(job.id) }
        return ok
    }

    @discardableResult
    public func remove(_ job: CronJob) async -> Bool {
        await self.perform(job.id, "cron.remove", ["id": .string(job.id)]) { _ in
            self.jobs.removeAll { $0.id == job.id }
            self.runs[job.id] = nil
        }
    }

    public func clearError(for jobId: String) {
        if self.operations[jobId]?.error != nil { self.operations[jobId] = nil }
    }

    public nonisolated static let newJobKey = "__new__"

    private func perform(_ key: String, _ method: String, _ params: JSONValue,
                         then: (JSONValue) async -> Void) async -> Bool
    {
        guard self.operations[key]?.isRunning != true else { return false }
        self.operations[key] = .running
        do {
            let result = try await self.connection.request(method, params, timeout: 60)
            await then(result)
            self.operations[key] = nil
            return true
        } catch {
            self.operations[key] = .failed(Self.message(for: error))
            return false
        }
    }

    static func isUnknownMethod(_ error: Error) -> Bool { GatewayConfigClient.isUnknownMethod(error) }

    static func message(for error: Error) -> String {
        guard case let GatewayError.rpc(_, message, details) = error else { return error.localizedDescription }
        if details?["code"]?.string == "MISSING_SCOPE" || message.lowercased().contains("operator.admin") {
            return "Changing automations needs Full Management access. Turn it on under Gateway Settings → Connection, then approve this device on the Gateway host."
        }
        if message.lowercased().contains("revision") {
            return "This automation changed on the Gateway. The latest version is loaded; review it and try again."
        }
        return message
    }
}
