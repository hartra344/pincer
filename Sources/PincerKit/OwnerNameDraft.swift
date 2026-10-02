import Foundation
import Observation

/// Keeps display-name keystrokes local to the Settings field and persists only after a short idle.
@MainActor
@Observable
public final class OwnerNameDraft {
    public static let storageKey = "pincer.ownerName"

    public private(set) var text: String

    @ObservationIgnored private let writer: OwnerNameDefaultsWriter
    @ObservationIgnored private let idleDelay: Duration
    @ObservationIgnored private let wait: @Sendable (Duration) async -> Void
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    package init(
        defaults: UserDefaults,
        idleDelay: Duration = .milliseconds(300),
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.text = defaults.string(forKey: Self.storageKey) ?? ""
        self.writer = OwnerNameDefaultsWriter(defaults: ThreadSafeDefaults(defaults), key: Self.storageKey)
        self.idleDelay = idleDelay
        self.wait = wait
    }

    /// Updates the visible draft synchronously; a bounded idle task persists the latest value.
    public func update(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        self.scheduleWrite()
    }

    /// Flushes the current value when the user submits the field or leaves the section.
    public func flush() async {
        self.pendingWrite?.cancel()
        self.pendingWrite = nil
        self.generation &+= 1
        await self.writer.write(self.text, generation: self.generation)
    }

    private func scheduleWrite() {
        self.pendingWrite?.cancel()
        self.generation &+= 1
        let generation = self.generation
        let text = self.text
        let idleDelay = self.idleDelay
        let writer = self.writer
        let wait = self.wait
        self.pendingWrite = Task { [weak self] in
            await wait(idleDelay)
            guard !Task.isCancelled else { return }
            await writer.write(text, generation: generation)
            guard let self, self.generation == generation else { return }
            self.pendingWrite = nil
        }
    }
}

/// Serializes the tiny durable write away from the main actor and rejects stale queued edits.
actor OwnerNameDefaultsWriter {
    private let defaults: ThreadSafeDefaults
    private let key: String
    private var latestGeneration: UInt64 = 0

    init(defaults: ThreadSafeDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func write(_ value: String, generation: UInt64) {
        guard generation > self.latestGeneration else { return }
        self.latestGeneration = generation
        guard self.defaults.value.string(forKey: self.key) != value else { return }
        self.defaults.value.set(value, forKey: self.key)
    }
}

/// UserDefaults documents its access as thread-safe. This wrapper transfers only that reference to
/// the serial writer actor; the observable draft itself remains isolated to the main actor.
final class ThreadSafeDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}
