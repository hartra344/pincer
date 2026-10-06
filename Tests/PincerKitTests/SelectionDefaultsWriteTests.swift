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

@MainActor
@Suite("Selection defaults write (#571)")
struct SelectionDefaultsWriteTests {
    /// A write to a suite is a synchronous XPC call to cfprefsd that stalled chat switches.
    @Test func selectingAChatWritesTheSelectionOffMain() {
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
        DefaultsWriter.flush()
        #expect(defaults.string(forKey: key) == "agent:main:switch-b", "writes keep their order")
    }
}
