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
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundRefresh.taskIdentifier, using: .main) { task in
            let job = Job(task)
            MainActor.assumeIsolated { job.start() }
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
        private var work: Task<Void, Never>?
        private var finished = false

        init(_ task: BGTask) { self.task = task }

        func start() {
            if ClosedAppDelivery.current() == .backgroundRefresh, Notifier.shared.enabled {
                BackgroundRefreshTask.schedule()
            } else {
                BackgroundRefreshTask.cancel()
            }
            self.task.expirationHandler = { [weak self] in
                MainActor.assumeIsolated { self?.work?.cancel() }
            }
            self.work = Task { @MainActor in
                let report = await BackgroundRefresh().run()
                self.finish(success: report.aborted.isEmpty && report.failed.isEmpty)
            }
        }

        private func finish(success: Bool) {
            guard !self.finished else { return }
            self.finished = true
            self.task.setTaskCompleted(success: success && self.work?.isCancelled != true)
        }
    }
}
