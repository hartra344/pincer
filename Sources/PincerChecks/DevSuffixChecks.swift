import Foundation

/// Exercises the shared suffix validator directly. The generated-project phase integration
/// requires XcodeGen and is intentionally covered by its separate opt-in Python mode.
@MainActor
func runDevSuffixValidatorChecks() async {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/test_xcode_dev_suffix.py")
    let result = await Task.detached(priority: .utility) {
        runBundleHarness(script: script, arguments: ["--direct"])
    }.value

    check(!result.timedOut, "direct development suffix validator checks finish within 30 seconds")
    check(!result.outputWasTruncated, "direct development suffix validator output stays within 32 KiB")
    check(result.output.contains("Ran 2 tests"),
          "direct development suffix validator executes its valid and invalid input cases\n\(result.output)")
    check(result.status == 0,
          "direct development suffix validator accepts canonical values and rejects malformed values\n\(result.output)")
}
