import PincerKit

/// Also run in Demo infrastructure: local inline image input, not a Gateway response claim.
@MainActor func runImageLoaderTerminalProofChecks() async {
    #if DEBUG
    do {
        let evidence = try await inspectImageLoaderTerminal()
        check(evidence.activeAtAdmission == 3, "actual inline image requests admitted before terminal observation")
        check(evidence.terminal, "actual evicting loader fetch tasks complete")
        check(evidence.failures == 0 && evidence.exactPixels, "actual decoded one-pixel images have no failures")
        check(evidence.retained == 1 && evidence.retained < evidence.admitted, "actual byte budget evicts completed images")
        guard evidence.activeAtAdmission == 3 && evidence.terminal && evidence.failures == 0 && evidence.exactPixels else { return }
        check(evidence.probeReportsComplete, "actual RSS completion decision recognizes finished evicting loader")
    } catch { check(false, "actual image loader terminal proof setup: \(error)") }
    #endif
}
