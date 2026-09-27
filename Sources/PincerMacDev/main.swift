import PincerKit
import PincerUI
import SwiftUI

#if os(macOS)
import AppKit

/// SwiftPM entry point (used by `scripts/bundle-mac.sh`). The Xcode app target uses the same scene.
struct PincerMacApp: App {
    @NSApplicationDelegateAdaptor(NotificationAppDelegate.self) private var delegate

    init() {
        // Running unbundled via `swift run` needs an explicit activation policy to get a Dock icon and menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        PincerScene()
    }
}

// `--avatar-snapshots <dir>` renders the avatar art to PNGs and exits, for reviewing it.
if let index = CommandLine.arguments.firstIndex(of: "--avatar-snapshots") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "avatar-snapshots"
    let directory = URL(filePath: (path as NSString).expandingTildeInPath)
    do {
        let count = try MainActor.assumeIsolated { try AvatarSnapshots.write(to: directory) }
        print("Wrote \(count) images to \(directory.path)")
        exit(0)
    } catch {
        print("Couldn't write avatar snapshots: \(error)")
        exit(1)
    }
}

// TEMP (screenshots): PINCER_FR_STOP=<n> walks the first-run wizard n steps against a mock gateway.
if let stop = ProcessInfo.processInfo.environment["PINCER_FR_STOP"].flatMap(Int.init) {
    let url = ProcessInfo.processInfo.environment["PINCER_FR_URL"] ?? "ws://127.0.0.1:18875"
    Task { @MainActor in
        let model = AppModel.shared.firstRun
        let steps: [(Double, () -> Void)] = [
            (4.0, { model.send(.getStarted) }),
            (2.0, { model.send(.answerHaveGateway(false)) }),
            (2.0, { model.send(.installed) }),
            (3.0, { model.send(.setLocation(.tailscale)) }),
            (2.0, { model.send(.setAddress("my-mac.tail1234.ts.net")) }),
            (2.0, { model.send(.setAddress("ws://203.0.113.9:18789")); model.send(.checkAddress) }),
            (2.0, { model.send(.setLocation(.sameNetwork)); model.send(.setAddress("127.0.0.1:18876")); model.send(.checkAddress) }),
            (9.5, { model.send(.setAddress(url)); model.send(.checkAddress) }),
            (2.0, { model.secret = "wrong-token"; model.send(.signIn(hasSecret: true)) }),
            (4.0, { model.secret = "dev-token"; model.send(.signIn(hasSecret: true)) }),
            (30.0, { model.send(.setName("Studio")) }),
            (1.0, { model.send(.continueToSetup) }),
        ]
        for (index, step) in steps.enumerated() where index < stop {
            try? await Task.sleep(for: .seconds(step.0))
            step.1()
        }
    }
}

PincerMacApp.main()
#endif
