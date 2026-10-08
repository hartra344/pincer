import Foundation
import PincerKit

@MainActor
func runReleasePrivacyChecks() async {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["test_release_privacy.py", "test_release_ci.py"] {
        let script = root.appendingPathComponent("scripts/\(name)")
        let result = await Task.detached(priority: .utility) { runBundleHarness(script: script) }.value
        check(!result.timedOut && !result.outputWasTruncated && result.status == 0,
              "release readiness: \(name) regressions pass\n\(result.output)")
    }
    check(AppLinks.privacy.scheme == "https" && AppLinks.support.scheme == "https",
          "release privacy: first-run and Settings use HTTPS product links")
}
