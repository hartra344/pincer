import Foundation
@testable import PincerUI

private enum WarmMemoFixtureError: Error { case admissionRejected }

private final class WarmMemoFixtureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Functional readiness awaits the real worker, rather than requiring its result inside a
/// bounded product warm pass. Cancellation invalidates intent but never resumes before that
/// worker's actual callback releases its admission lease.
@MainActor func prepareWarmMemoFixtureRows(
    _ job: PremeasureJob, driver: TranscriptPremeasureDriver, env: TextBuildEnvironment,
    observeSubmitted: @escaping @MainActor @Sendable () -> Void = {}
) async throws -> [PremeasuredRow] {
    let cancellation = WarmMemoFixtureCancellation()
    let rows: [PremeasuredRow] = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        if cancellation.isCancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            let admitted = driver.admission.submit(job, env: env, epoch: driver.epoch) { rows in
                continuation.resume(returning: rows)
                // Admission synchronously releases its lease after this callback returns,
                // before the waiting MainActor task can resume.
            }
            guard admitted else {
                continuation.resume(throwing: WarmMemoFixtureError.admissionRejected)
                return
            }
            observeSubmitted()
        }
    } onCancel: {
        cancellation.cancel()
    }
    // Even if cancellation raced the callback, the actual owned work has now drained.
    try Task.checkCancellation()
    if cancellation.isCancelled { throw CancellationError() }
    return rows
}
