import Foundation

/// Writes defaults off the main thread, in order (#571). A write to a suite is a synchronous XPC
/// round trip to cfprefsd, which stalled chat switches by up to a few hundred milliseconds when
/// the daemon was busy. Reads in the same process see a value once its write has run.
public enum DefaultsWriter {
    private static let queue = DispatchQueue(label: "pincer.defaults-writer", qos: .utility)

    public static func set(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        self.queue.async { defaults.set(value, forKey: key) }
    }

    /// Waits for every write queued so far. For tests and before reading a value just written.
    public static func flush() {
        self.queue.sync {}
    }
}
