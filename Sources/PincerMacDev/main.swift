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

// `--first-run-screens <dir> [gateway-url]` walks the first-run wizard against a fresh mock Gateway
// (token dev-token, MOCK_PAIRING=auto), saves a PNG of the window at each step, removes the gateway it
// added and quits. For reviewing the wizard; see FirstRunTour.
#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--first-run-screens") {
    let rest = CommandLine.arguments.dropFirst(index + 1)
    let path = rest.first ?? "first-run-screens"
    let url = rest.dropFirst().first ?? "ws://127.0.0.1:18789"
    let directory = URL(filePath: (path as NSString).expandingTildeInPath)
    Task { @MainActor in
        let code = await FirstRunTour.run(to: directory, gatewayURL: url)
        exit(code)
    }
}
#endif
// `--sidebar-working-snapshots <dir>` renders the sidebar's working indicator to PNGs and exits.
if let index = CommandLine.arguments.firstIndex(of: "--sidebar-working-snapshots") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "sidebar-working-snapshots"
    let directory = URL(filePath: (path as NSString).expandingTildeInPath)
    do {
        let count = try MainActor.assumeIsolated { try SidebarWorkingSnapshots.write(to: directory) }
        print("Wrote \(count) images to \(directory.path)")
        exit(0)
    } catch {
        print("Couldn't write sidebar working snapshots: \(error)")
        exit(1)
    }
}

PincerMacApp.main()
#endif
