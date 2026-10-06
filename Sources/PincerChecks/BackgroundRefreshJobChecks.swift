import Foundation
import PincerKit

// #930: a BGTask's expiration handler runs on a background queue; it must not trap, and the task
// completes exactly once.

@MainActor
func runBackgroundRefreshJobChecks() async {
    var completions: [Bool] = []
    let job = BackgroundRefreshJob(
        work: {
            try? await Task.sleep(for: .seconds(3600))
            return true
        },
        complete: { completions.append($0) })
    job.start()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .utility).async {
            job.expire()
            done.resume()
        }
    }
    let completed = await waitFor("background refresh job expiry", timeout: 3) { !completions.isEmpty }
    check(completed && completions == [false], "off-main expiry completes the task unsuccessfully")
    try? await Task.sleep(for: .milliseconds(100))
    check(completions == [false], "expiry completes the task only once")

    var finishedRun: [Bool] = []
    let quick = BackgroundRefreshJob(work: { true }, complete: { finishedRun.append($0) })
    quick.start()
    _ = await waitFor("background refresh job finish", timeout: 3) { !finishedRun.isEmpty }
    quick.expire()
    try? await Task.sleep(for: .milliseconds(50))
    check(finishedRun == [true], "a late expiry after the run finished is ignored")

    check(BackgroundRefresh.defaultBudget <= 20, "refresh budget ends well inside the system window")
}
