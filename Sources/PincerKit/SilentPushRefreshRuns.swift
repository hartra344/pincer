import Foundation
import PincerPush

/// Runs silent-push refreshes one at a time. A burst of pushes (reply + approval) would otherwise
/// start two refreshes against the same cursor and post the same items twice; the run in flight
/// catches up on the later push too.
@MainActor
public final class SilentPushRefreshRuns {
    public static let shared = SilentPushRefreshRuns()

    private var current: SilentPushRefresh?

    public init() {}

    public var isRunning: Bool { self.current != nil }

    /// `completion` fires exactly once: `.noData` at once when the push isn't ours to handle or a run
    /// is in flight, otherwise with the run's result. The run is retained until it completes.
    public func handle(
        _ userInfo: [AnyHashable: Any], appIsActive: Bool, defaults: UserDefaults = .standard,
        keys: (UUID) -> WebPushKeys? = PushKeyStore.keys(for:),
        make: (_ userInfo: [AnyHashable: Any], _ completion: @escaping @MainActor (SilentPushRefresh.Result) -> Void)
            -> SilentPushRefresh = { SilentPushRefresh(userInfo: $0, completion: $1) },
        completion: @escaping @MainActor (SilentPushRefresh.Result) -> Void)
    {
        guard SilentPushRefresh.shouldHandle(userInfo, appIsActive: appIsActive, defaults: defaults) else {
            completion(.noData)
            return
        }
        if let current {
            current.cover(userInfo: userInfo, keys: keys)
            completion(.noData)
            return
        }
        let run = make(userInfo) { [weak self] result in
            self?.current = nil
            completion(result)
        }
        self.current = run
        run.start()
    }
}
