#if os(macOS)
import AppKit

/// ⌘R: restarts the whole process, like reloading a web page. Persisted state (profiles, caches, settings) survives.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = Array(CommandLine.arguments.dropFirst())
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error {
                        NSSound.beep()
                        NSLog("Pincer relaunch failed: \(error)")
                    } else {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        } else if let executable = Bundle.main.executableURL {
            // Unbundled (`swift run`): start the binary again directly.
            let process = Process()
            process.executableURL = executable
            process.arguments = Array(CommandLine.arguments.dropFirst())
            do {
                try process.run()
                NSApplication.shared.terminate(nil)
            } catch {
                NSSound.beep()
                NSLog("Pincer relaunch failed: \(error)")
            }
        }
    }
}
#endif
