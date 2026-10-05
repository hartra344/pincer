import Foundation
import PincerKit

@MainActor func runCatalogWorkerGateChecks() async {
    #if DEBUG && os(macOS)
    do {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let result = try await runCatalogWorkerGateChild(executable: executable)
        guard let evidence = result.evidence else {
            check(false, "strict owned child completed with actual worker evidence")
            return
        }
        check(evidence.strictEnvironment, "strict runtime environment inherited before child startup")
        check(evidence.actualLeaseHeld && evidence.noEarlyPublication, "actual worker lease held without early catalog publication")
        check(evidence.continuationBeforeFallback, "same-QoS continuation progresses before external fallback")
        check(evidence.exactCompletion && evidence.idleAfterCompletion, "actual worker completed exact catalog and released lease")
        check(result.status == 0, "strict worker fixture child passed")
    } catch { check(false, "strict owned worker child setup: \(error)") }
    #endif
}
