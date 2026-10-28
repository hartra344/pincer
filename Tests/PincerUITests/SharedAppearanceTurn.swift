import Foundation
import Testing

/// Every live `TranscriptRenderer` watches the app's appearance and `UserDefaults.standard` (theme,
/// thinking, reactions, avatars) and rebuilds its rows when they change. A test that changes them
/// therefore rebuilds the rows of whatever transcript another suite is measuring at that moment: on CI
/// that showed up as `PanelSlideProbe` layout builds during a frozen slide and a 177 pt bottom drift.
///
/// Tests that change that process-wide state take an exclusive turn (`.changesSharedAppearance`);
/// tests that measure live transcripts share a turn with each other (`.readsSharedAppearance`).
struct SharedAppearanceTrait: SuiteTrait, TestTrait, TestScoping {
    let exclusive: Bool

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        let turn = SharedAppearanceTurn.shared
        await turn.acquire(exclusive: self.exclusive)
        do { try await function() } catch {
            await self.release(turn)
            throw error
        }
        await self.release(turn)
    }

    private func release(_ turn: SharedAppearanceTurn) async {
        // Renderers hear an appearance change through KVO that hops to the main queue, so the change a
        // test makes (or reverts in a `defer`) can still be queued when it returns. Drain it first.
        if self.exclusive { await SharedAppearanceTurn.drainMainQueue() }
        await turn.release(exclusive: self.exclusive)
    }
}

extension Trait where Self == SharedAppearanceTrait {
    static var changesSharedAppearance: Self { Self(exclusive: true) }
    static var readsSharedAppearance: Self { Self(exclusive: false) }
}

/// An async reader/writer lock: waiting suspends rather than blocking a thread, and waiters are served
/// in arrival order so a stream of readers can't starve a writer.
actor SharedAppearanceTurn {
    static let shared = SharedAppearanceTurn()

    private var readers = 0
    private var writing = false
    private var waiters: [(exclusive: Bool, resume: CheckedContinuation<Void, Never>)] = []

    struct State: Equatable {
        var readers: Int
        var writing: Bool
    }

    var state: State { State(readers: self.readers, writing: self.writing) }

    func acquire(exclusive: Bool) async {
        if self.waiters.isEmpty, self.canEnter(exclusive: exclusive) {
            self.enter(exclusive: exclusive)
            return
        }
        await withCheckedContinuation { self.waiters.append((exclusive, $0)) }
    }

    func release(exclusive: Bool) {
        if exclusive { self.writing = false } else { self.readers -= 1 }
        while let next = self.waiters.first, self.canEnter(exclusive: next.exclusive) {
            self.waiters.removeFirst()
            self.enter(exclusive: next.exclusive)
            next.resume.resume()
        }
    }

    private func canEnter(exclusive: Bool) -> Bool {
        exclusive ? !self.writing && self.readers == 0 : !self.writing
    }

    private func enter(exclusive: Bool) {
        if exclusive { self.writing = true } else { self.readers += 1 }
    }

    /// Two hops through the main queue: one for the KVO callbacks already queued, one for any work they queue.
    static func drainMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
    }
}
