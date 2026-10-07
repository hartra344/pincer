import Foundation
import Network
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

/// A Gateway that's down in one particular way: accepts and never answers, answers garbage, or
/// hangs up at once.
final class DownGateway: @unchecked Sendable {
    enum Mode { case hang, garbage, hangUp }
    private let listener: NWListener
    private let lock = NSLock()
    private var held: [NWConnection] = []
    var port: UInt16 { self.listener.port?.rawValue ?? 0 }

    init?(_ mode: Mode) {
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            switch mode {
            case .hang:
                self?.lock.withLock { self?.held.append(connection) }
            case .garbage:
                let junk = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n\u{0}\u{ff}{]\"".utf8)
                connection.send(content: junk, completion: .contentProcessed { _ in connection.cancel() })
            case .hangUp:
                connection.cancel()
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success else { return nil }
    }

    func stop() {
        self.listener.cancel()
        self.lock.withLock { self.held.forEach { $0.cancel() } }
    }
}

/// #930: a background refresh against Gateways that are down (refused, hanging, garbage, hang-up)
/// ends inside its budget and reports each one, instead of running into the system's expiration.
@MainActor
func runBackgroundRefreshDownGatewayChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    ClosedAppDelivery.set(.backgroundRefresh, defaults)
    defaults.set(true, forKey: "pincer.notifications")
    guard let hang = DownGateway(.hang), let garbage = DownGateway(.garbage), let hangUp = DownGateway(.hangUp),
          let gone = DownGateway(.hangUp)
    else { return check(false, "down gateways listening") }
    let refusedPort = gone.port
    gone.stop()
    defer { [hang, garbage, hangUp].forEach { $0.stop() } }

    let profiles = [("refused", refusedPort), ("hanging", hang.port), ("garbage", garbage.port), ("hang-up", hangUp.port)]
        .map { GatewayProfile(name: $0.0, url: "ws://127.0.0.1:\($0.1)", authMode: .none) }
    var posted = 0
    var badges: [Int] = []
    let refresh = BackgroundRefresh(
        profiles: { profiles }, connector: GatewayIntentConnector(identity: { DeviceIdentity.loadOrCreate() }),
        cursors: BackgroundRefreshCursorStore(defaults: defaults), defaults: defaults,
        post: { posted += $0.count }, setBadge: { badges.append($0) })
    let clock = ContinuousClock(), start = clock.now
    let report = await refresh.run(budget: 2)
    let elapsed = clock.now - start
    check(elapsed < .seconds(4), "refresh against down gateways ends inside its budget (\(elapsed))")
    check(Set(report.aborted + report.failed) == Set(profiles.map(\.id)), "every down gateway is reported unreached")
    check(report.aborted.contains(profiles[1].id), "the hanging gateway is cut off at the budget")
    check(posted == 0 && badges.isEmpty && report.badge == nil, "nothing posted and the badge is left alone")
    check(defaults.string(forKey: "pincer.refresh.lastResult")?.contains("Couldn't reach") == true,
          "the run records that gateways couldn't be reached")
}
