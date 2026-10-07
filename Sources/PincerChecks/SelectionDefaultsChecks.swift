import Foundation
import Synchronization
import PincerKit

/// Records which thread each write runs on.
private final class MainWriteRecordingDefaults: UserDefaults, @unchecked Sendable {
    let mainThreadWrites = Mutex<[String]>([])

    override func set(_ value: Any?, forKey key: String) {
        if Thread.isMainThread { self.mainThreadWrites.withLock { $0.append(key) } }
        super.set(value, forKey: key)
    }
}

/// #571: switching chats doesn't wait on cfprefsd to save the selection.
@MainActor
func runSelectionDefaultsChecks() {
    let suite = "pincer.checks.\(UUID().uuidString)"
    guard let defaults = MainWriteRecordingDefaults(suiteName: suite) else {
        check(false, "selection defaults: scratch suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(suite).plist"))
    }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    let key = "pincer.selected.\(gateway.id.uuidString)"
    defaults.mainThreadWrites.withLock { $0.removeAll() }
    for index in 0..<20 { gateway.selectedKey = "agent:main:switch-\(index)" }
    check(!defaults.mainThreadWrites.withLock { $0.contains(key) }, "selection defaults: a chat switch saves its selection off main")
    DefaultsWriter.flush()
    check(defaults.string(forKey: key) == "agent:main:switch-19", "selection defaults: the last selection is the one saved")
}
