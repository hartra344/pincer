import BackgroundTasks
import PincerKit
import UIKit

/// Local notifications without a push server: iOS wakes Pincer now and then and
/// `BackgroundRefresh` posts what changed on the gateways.
@MainActor
enum BackgroundRefreshTask {
    private static var observer: NSObjectProtocol?

    /// Must run before `didFinishLaunching` returns.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundRefresh.taskIdentifier, using: .main) { @Sendable task in
            nonisolated(unsafe) let task = task
            MainHop.run { Job(task).start() }
        }
        self.observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main)
        { _ in
            MainActor.assumeIsolated { self.appDidEnterBackground() }
        }
    }

    static func appDidEnterBackground() {
        guard ClosedAppDelivery.current() == .backgroundRefresh, Notifier.shared.enabled else {
            self.cancel()
            return
        }
        BackgroundRefresh().seed(from: AppModel.shared.gateways)
        self.schedule()
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundRefresh.interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[Pincer] Couldn't schedule background refresh: %@", error.localizedDescription)
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefresh.taskIdentifier)
    }

    /// One system-launched run. `BGTask` isn't Sendable; it is only touched on the main actor.
    @MainActor
    private final class Job {
        private let task: BGTask
        private let job: BackgroundRefreshJob

        init(_ task: BGTask) {
            self.task = task
            self.job = BackgroundRefreshJob(
                work: {
                    let report = await BackgroundRefresh().run()
                    return report.aborted.isEmpty && report.failed.isEmpty
                },
                complete: { [task] success in
                    task.expirationHandler = nil
                    task.setTaskCompleted(success: success)
                })
        }

        func start() {
            if ClosedAppDelivery.current() == .backgroundRefresh, Notifier.shared.enabled {
                BackgroundRefreshTask.schedule()
            } else {
                BackgroundRefreshTask.cancel()
            }
            // Called on a background queue (#930): `@Sendable` so Swift doesn't assert main-actor
            // isolation on entry, and `expire` hops to main itself.
            self.task.expirationHandler = { @Sendable [job] in job.expire() }
            self.job.start()
        }
    }
}
