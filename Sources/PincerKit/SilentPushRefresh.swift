import Foundation
import PincerPush
import UserNotifications

/// One content-available wake from the push relay: catches up on what the push itself doesn't
/// carry (badge, questions, replies the gateway didn't push) without repeating what it did.
/// iOS gives the wake about 30 s, so everything is bounded by `deadline`.
@MainActor
public final class SilentPushRefresh {
    public enum Result: Sendable, Equatable { case newData, noData, failed }

    /// Hard stop: iOS gives a content-available wake ~30 s.
    public static let deadline: TimeInterval = 25

    @MainActor
    private final class State {
        var result = Result.failed
        var watchdog: Task<Void, Never>?
    }

    private let job: BackgroundRefreshJob
    private let state = State()
    private var started = false
    private let deadlineSeconds: TimeInterval
    private let timer: @Sendable (TimeInterval) async -> Void

    /// A Pincer relay payload, notifications on, mode push relay, app not active.
    public nonisolated static func shouldHandle(
        _ userInfo: [AnyHashable: Any], appIsActive: Bool, defaults: UserDefaults = .standard) -> Bool
    {
        guard !appIsActive, userInfo["pincer"] is [String: Any],
              defaults.object(forKey: "pincer.notifications") as? Bool ?? true,
              ClosedAppDelivery.current(defaults) == .pushRelay
        else { return false }
        return true
    }

    public init(
        userInfo: [AnyHashable: Any],
        refresh: BackgroundRefresh = BackgroundRefresh(),
        budget: TimeInterval = BackgroundRefresh.defaultBudget,
        deadline: TimeInterval = SilentPushRefresh.deadline,
        keys: (UUID) -> WebPushKeys? = PushKeyStore.keys(for:),
        timer: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        completion: @escaping @MainActor (Result) -> Void)
    {
        let pushed = PushMessage(apnsPayload: userInfo, keys: keys).map(PushedTargets.init(message:)) ?? PushedTargets()
        let state = self.state
        self.deadlineSeconds = deadline
        self.timer = timer
        self.job = BackgroundRefreshJob(
            work: {
                let report = await refresh.run(budget: budget, trigger: .silentPush(pushed))
                state.result = Self.map(report)
                return state.result != .failed
            },
            complete: { success in
                state.watchdog?.cancel()
                completion(success ? state.result : .failed)
            })
    }

    public func start() {
        guard !self.started else { return }
        self.started = true
        let job = self.job
        let seconds = self.deadlineSeconds
        let timer = self.timer
        self.state.watchdog = Task {
            await timer(seconds)
            guard !Task.isCancelled else { return }
            job.expire()
        }
        self.job.start()
    }

    nonisolated static func map(_ report: BackgroundRefresh.Report) -> Result {
        if report.skipped { return .noData }
        if report.posted > 0 { return .newData }
        if !report.aborted.isEmpty || !report.failed.isEmpty { return .failed }
        return .noData
    }
}
