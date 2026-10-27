import Foundation

/// iOS: background time asked for when Pincer leaves the foreground, so its Gateway connections (and
/// a reply still streaming in) survive a quick app switch instead of dying with the suspended app
/// (#1074). Nothing is closed when the app goes to the background; once the time runs out,
/// `onExpire` pauses what can't work while suspended (device mode's node connection).
@MainActor
public final class BackgroundConnectionGrace {
    /// Begins a background activity named by the first argument; the second runs if the system's
    /// time runs out. Returns the closure that ends it. Wraps `UIApplication.beginBackgroundTask`.
    public typealias Begin = @MainActor (String, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    static let activityName = "Keep Gateway connections"

    /// Whether background time is held right now.
    public var isHeld: Bool { self.end != nil }
    /// Set when the system's background time ran out, until the app returns to the foreground.
    public private(set) var expired = false
    var onExpire: @MainActor () -> Void = {}

    /// Tests swap in a fake.
    public var begin: Begin
    private var end: (@MainActor () -> Void)?
    private var token = 0

    public init(begin: @escaping Begin = { name, expired in Notifier.shared.beginBackgroundActivity(name, expired) }) {
        self.begin = begin
    }

    func enterBackground() {
        guard self.end == nil, !self.expired else { return }
        self.token &+= 1
        let token = self.token
        self.end = self.begin(Self.activityName) { [weak self] in
            guard let self, self.token == token else { return }
            self.end = nil
            self.expired = true
            self.onExpire()
        }
    }

    func enterForeground() {
        self.token &+= 1
        let end = self.end
        self.end = nil
        self.expired = false
        end?()
    }
}

/// Resumes a ping's continuation once, with whichever of the pong or the timeout comes first.
final class PingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        self.lock.withLock { self.continuation = continuation }
    }

    func finish(_ answered: Bool) {
        let continuation = self.lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: answered)
    }
}
