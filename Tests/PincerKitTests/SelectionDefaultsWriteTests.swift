import Foundation
import Synchronization
import Testing
@testable import PincerKit

/// Records which thread each write runs on.
private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    let mainThreadWrites = Mutex<[String]>([])

    override func set(_ value: Any?, forKey key: String) {
        if Thread.isMainThread { self.mainThreadWrites.withLock { $0.append(key) } }
        super.set(value, forKey: key)
    }
}

/// A write slow enough that a flush is still waiting when its change notification posts.
private final class SlowDefaults: UserDefaults, @unchecked Sendable {
    override func set(_ value: Any?, forKey key: String) {
        Thread.sleep(forTimeInterval: 0.1)
        super.set(value, forKey: key)
    }
}

@MainActor
@Suite("Selection defaults write (#571)")
struct SelectionDefaultsWriteTests {
    /// A write to a suite is a synchronous XPC call to cfprefsd that stalled chat switches.
    @Test func selectingAChatWritesTheSelectionOffMain() async {
        let name = "pincer.tests.\(UUID().uuidString)"
        let defaults = RecordingDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(name).plist"))
        }
        let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: Fixtures.identity())
        let key = "pincer.selected.\(gateway.id.uuidString)"
        defaults.mainThreadWrites.withLock { $0.removeAll() }
        gateway.selectedKey = "agent:main:switch-a"
        gateway.selectedKey = "agent:main:switch-b"
        #expect(!defaults.mainThreadWrites.withLock { $0.contains(key) })
        await DefaultsWriter.flush()
        #expect(defaults.string(forKey: key) == "agent:main:switch-b", "writes keep their order")
    }

    /// #920: transcripts observe defaults changes on the main queue, so a write's notification
    /// post waits for main. Flushing from main must not block it, or the two wait on each other.
    @Test func flushFromMainWhileAMainQueueObserverWaitsDoesNotDeadlock() async {
        let name = "pincer.tests.\(UUID().uuidString)"
        let defaults = SlowDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(name).plist"))
        }
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in }
        defer { NotificationCenter.default.removeObserver(observer) }
        DefaultsWriter.set("written", forKey: "flush-probe", in: defaults)
        await DefaultsWriter.flush()
        #expect(defaults.string(forKey: "flush-probe") == "written")
    }
}
