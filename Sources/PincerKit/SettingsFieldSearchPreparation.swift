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
    fileprivate struct Index: Sendable {
        let source: GatewaySettingsModel.FieldSearchSourceRevision
        let fields: [ConfigField]
        let haystacks: [String]
        let bytes: Int
    }
    fileprivate struct Output: Sendable {
        let fields: [ConfigField]
        let cache: Index?
    }
    @MainActor package final class Ticket {
        let token: UUID
        fileprivate var result: [ConfigField]?
        fileprivate var finished = false
        fileprivate var waiter: CheckedContinuation<Void, Never>?
        fileprivate var job: LatestWinsPreparer<Output>.Ticket?
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
    private struct Active {
        let cachedCount: Int
        let cachedBytes: Int
    }
    private var cache: Index?
    private var active: Active?
    private var latestToken: UUID?
    private let preparer = LatestWinsPreparer<Output>()
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
        BudgetSnapshot(activeCount: self.preparer.activeCount, pendingCount: self.preparer.pendingCount,
                       cachedCount: self.cache?.fields.count ?? self.active?.cachedCount ?? 0,
                       cachedBytes: self.cache?.bytes ?? self.active?.cachedBytes ?? 0,
                       pendingToken: self.preparer.pendingCount == 0 ? nil : self.latestToken)
    }
    package func enqueue(_ input: Input) -> Ticket {
        let ticket = Ticket(token: input.token)
        self.latestToken = input.token
        ticket.job = self.preparer.submit(start: { [self] in
            // The worker owns the prior cache reference, including disposal on a source miss.
            let cached = self.cache
            self.active = Active(cachedCount: cached?.fields.count ?? 0, cachedBytes: cached?.bytes ?? 0)
            self.cache = nil
            return { Self.prepare(input, cached: cached?.source == input.source ? cached : nil) }
        }, finished: { [self] output in
            // Even a superseded or cancelled worker hands its index back and finishes its own ticket.
            self.cache = output.cache
            self.active = nil
            ticket.finish(output.fields)
        }, completion: { ticket.finish($0?.fields) })
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
        // Active ownership stays occupied until the real worker exits, even if its waiter cancels.
        if let job = ticket.job { self.preparer.cancel(job) }
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
        guard !self.preparer.isIdle, !Task.isCancelled else { return }
        await self.preparer.waitForIdle()
    }
    #endif
}
