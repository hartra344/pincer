import Foundation

/// One active exact search and one replaceable latest request per settings model.
/// Captured schema/config/query storage is COW and input-proportional. Only the normalized
/// index is cached, within explicit logical-byte and field-count budgets.
@MainActor
package final class SettingsFieldSearchPreparation {
    package nonisolated static let cacheByteLimit = 4 * 1024 * 1024
    package nonisolated static let cacheFieldLimit = 4096
    package struct Input: Sendable {
        let token: UUID
        let source: GatewaySettingsModel.FieldSearchSourceRevision
        let schema: ConfigSchema
        let config: JSONValue
        let query: String
        #if DEBUG
        let probe: SettingsFieldSearchProbe?
        let beforeWork: (@Sendable () -> Void)?
        #endif
    }
    private struct Index: Sendable {
        let source: GatewaySettingsModel.FieldSearchSourceRevision
        let fields: [ConfigField]
        let haystacks: [String]
        let bytes: Int
    }
    private struct Output: Sendable {
        let fields: [ConfigField]
        let cache: Index?
    }
    @MainActor package final class Ticket {
        let token: UUID
        fileprivate var result: [ConfigField]?
        fileprivate var finished = false
        fileprivate var waiter: CheckedContinuation<Void, Never>?
        init(token: UUID) { self.token = token }
        fileprivate func finish(_ fields: [ConfigField]?) {
            guard !self.finished else { return }
            self.finished = true; self.result = fields
            let waiter = self.waiter; self.waiter = nil; waiter?.resume()
        }
        fileprivate func wait() async {
            await withCheckedContinuation { continuation in
                if self.finished { continuation.resume() } else { self.waiter = continuation }
            }
        }
    }
    // Main installs storage before admission; only the worker consumes/clears it once active.
    // Completion retains no schema/config/query after the worker has finished.
    private final class WorkStorage: @unchecked Sendable {
        var input: Input?
        var cache: Index?
        init(_ input: Input) { self.input = input }
        func prepare() -> Output {
            guard let input else { preconditionFailure("search input already consumed") }
            let output = SettingsFieldSearchPreparation.prepare(input, cached: self.cache?.source == input.source ? self.cache : nil)
            self.input = nil
            self.cache = nil
            return output
        }
    }
    private struct Job {
        let token: UUID
        let storage: WorkStorage
        let ticket: Ticket
    }
    private struct Active {
        let cachedCount: Int
        let cachedBytes: Int
    }
    private var cache: Index?
    private var active: Active?
    private var pending: Job?
    private var worker: Task<Void, Never>?
    #if DEBUG
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    #endif
    package func cachedFields(for source: GatewaySettingsModel.FieldSearchSourceRevision) -> [ConfigField] {
        self.cache?.source == source ? self.cache?.fields ?? [] : []
    }
    package struct BudgetSnapshot {
        package let activeCount: Int
        package let pendingCount: Int
        package let cachedCount: Int
        package let cachedBytes: Int
        package let pendingToken: UUID?
    }
    package var budgetSnapshot: BudgetSnapshot {
        BudgetSnapshot(activeCount: self.active == nil ? 0 : 1, pendingCount: self.pending == nil ? 0 : 1,
                       cachedCount: self.cache?.fields.count ?? self.active?.cachedCount ?? 0,
                       cachedBytes: self.cache?.bytes ?? self.active?.cachedBytes ?? 0, pendingToken: self.pending?.token)
    }
    package func enqueue(_ input: Input) -> Ticket {
        let ticket = Ticket(token: input.token)
        self.pending?.ticket.finish(nil)
        self.pending = Job(token: input.token, storage: WorkStorage(input), ticket: ticket)
        self.start()
        return ticket
    }
    package func wait(_ ticket: Ticket) async -> [ConfigField]? {
        await withTaskCancellationHandler {
            if Task.isCancelled { self.cancel(ticket) }
            await ticket.wait()
        } onCancel: {
            Task { @MainActor [weak self, weak ticket] in
                guard let ticket else { return }
                self?.cancel(ticket)
            }
        }
        return Task.isCancelled ? nil : ticket.result
    }
    private func cancel(_ ticket: Ticket) {
        ticket.finish(nil)
        if self.pending?.ticket === ticket { self.pending = nil }
        // Active ownership stays occupied until the real worker exits, even if its waiter cancels.
    }
    private func start() {
        guard self.active == nil, let job = self.pending else { return }
        self.pending = nil
        let storage = job.storage
        storage.cache = self.cache
        self.active = Active(cachedCount: self.cache?.fields.count ?? 0, cachedBytes: self.cache?.bytes ?? 0)
        // The worker now owns the prior cache reference, including disposal on a source miss.
        self.cache = nil
        let preparation = Task.detached(priority: .userInitiated) { storage.prepare() }
        let ticket = job.ticket
        self.worker = Task { [weak self] in
            let output = await preparation.value
            guard let self else { ticket.finish(nil); return }
            self.cache = output.cache
            ticket.finish(output.fields)
            self.active = nil; self.worker = nil
            self.start()
            #if DEBUG
            if self.active == nil && self.pending == nil {
                let waiters = self.idleWaiters; self.idleWaiters.removeAll()
                for waiter in waiters.values { waiter.resume() }
            }
            #endif
        }
    }
    private nonisolated static func prepare(_ input: Input, cached: Index?) -> Output {
        #if DEBUG
        input.beforeWork?()
        #endif
        let index: Index
        if let cached { index = cached }
        else {
            #if DEBUG
            input.probe?.record(.traversal)
            #endif
            let fields = input.schema.searchIndex(config: input.config)
            var haystacks: [String] = []
            haystacks.reserveCapacity(fields.count)
            var bytes = 0
            for field in fields {
                #if DEBUG
                input.probe?.record(.normalization)
                #endif
                let text = ([field.label, field.help ?? ""] + field.path).joined(separator: " ").lowercased()
                haystacks.append(text)
                // Stop accounting once retention is ruled out; matching still examines every field.
                if bytes <= Self.cacheByteLimit {
                    bytes += text.utf8.count + Self.fieldBytes(field) + 256
                }
            }
            index = Index(source: input.source, fields: fields, haystacks: haystacks, bytes: bytes)
        }
        #if DEBUG
        input.probe?.record(.matching)
        #endif
        let terms = input.query.lowercased().split(separator: " ").map(String.init)
        var results: [ConfigField] = []
        for (field, text) in zip(index.fields, index.haystacks) {
            if terms.allSatisfy({ text.contains($0) }) && results.count < 60 { results.append(field) }
        }
        return Output(fields: results, cache: index.fields.count <= Self.cacheFieldLimit && index.bytes <= Self.cacheByteLimit ? index : nil)
    }
    private nonisolated static func fieldBytes(_ field: ConfigField) -> Int {
        var bytes = field.path.reduce(0) { $0 + $1.utf8.count + 24 }
        for text in [field.label, field.help, field.placeholder, field.pattern, field.signupURL?.absoluteString].compactMap({ $0 }) {
            bytes += text.utf8.count + 24
        }
        if case let .choice(values) = field.kind { bytes += values.reduce(0) { $0 + $1.utf8.count + 24 } }
        if let value = field.defaultValue { bytes += Self.valueBytes(value) }
        return bytes
    }
    private nonisolated static func valueBytes(_ value: JSONValue) -> Int {
        switch value {
        case let .string(text): return text.utf8.count + 24
        case let .array(values): return values.reduce(24) { $0 + Self.valueBytes($1) }
        case let .object(values): return values.reduce(24) { $0 + $1.key.utf8.count + 48 + Self.valueBytes($1.value) }
        default: return 16
        }
    }
    #if DEBUG
    package func drain() async {
        guard self.active != nil || self.pending != nil, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || (self.active == nil && self.pending == nil) { continuation.resume() }
                else { self.idleWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.idleWaiters.removeValue(forKey: id)?.resume() }
        }
    }
    #endif
}
