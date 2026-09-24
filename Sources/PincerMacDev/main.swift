import PincerUI
import SwiftUI

#if os(macOS)
import AppKit

/// SwiftPM entry point (used by `scripts/bundle-mac.sh`). The Xcode app target uses the same scene.
struct PincerMacApp: App {
    init() {
        // Running unbundled via `swift run` needs an explicit activation policy to get a Dock icon and menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        PincerScene()
    }
}

PincerMacApp.main()
#endif
