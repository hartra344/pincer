#if DEBUG && os(macOS)
import Foundation

package struct UnitNativeRetentionEvidence: Sendable {
    package let actualFailureQualified: Bool
    package let retainedOwnedArtifacts: Bool
    package let boundedManifest: Bool
}
private func retentionIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { done in
        DispatchQueue.global(qos: .utility).async { @Sendable in
            do { done.resume(returning: try body()) } catch { done.resume(throwing: error) }
        }
    }
}
package func unitNativeRetentionProof() async throws -> UnitNativeRetentionEvidence {
    let root = try await retentionIO {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-retention-control-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    do {
        let actual = try await unitNativeBacktraceProof(backtraceOverrideForTesting: "enable=no", retentionRootForTesting: root)
        let result = try await retentionIO {
            let qualified = actual.ordinaryPassed && actual.crashOwnedStatus && !actual.crashBacktracePassed
            guard let phase = actual.phases.first(where: { $0.mode == "crash" }),
                  let path = phase.retainedFailureDirectory else {
                return UnitNativeRetentionEvidence(actualFailureQualified: qualified, retainedOwnedArtifacts: false, boundedManifest: false)
            }
            let directory = URL(fileURLWithPath: path)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("unit-command-exit.json"))) as? [String: Any]
            let output = String(decoding: try Data(contentsOf: directory.appendingPathComponent("output.txt")), as: UTF8.self)
            let marker = "PINCER_NATIVE_CRASH_PID="
            let pid = output.split(whereSeparator: \.isNewline).first { $0.hasPrefix(marker) }.flatMap { Int($0.dropFirst(marker.count)) }
            let saved = try JSONDecoder().decode(UnitNativePhaseEvidence.self, from: Data(contentsOf: directory.appendingPathComponent("phases.json")))
            var total = 0
            for name in names {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
                total += (attributes[.size] as? NSNumber)?.intValue ?? Int.max / 100
            }
            let owned = (pid ?? 0) > 0 && pid == (metadata?["ownedPid"] as? Int)
                && (metadata?["ownedReturnCode"] as? Int) == -11 && (metadata?["timedOut"] as? Bool) == false
                && actual.crashStatus == 139 && !output.contains("Signal 11")
            let bounded = names.count <= 17 && total <= 2 * 1024 * 1024
                && saved.retentionManifest.count <= 16 && !saved.artifactCopyError
                && saved.retentionManifest.allSatisfy { entry in
                    entry.copiedBytes <= 256 * 1024 && (entry.outcome != "copied" ||
                        (entry.sourceBytes != nil && entry.truncated == (Int64(entry.copiedBytes) < entry.sourceBytes!)))
                }
            return UnitNativeRetentionEvidence(actualFailureQualified: qualified, retainedOwnedArtifacts: owned, boundedManifest: bounded)
        }
        try await retentionIO { try FileManager.default.removeItem(at: root) }
        return result
    } catch {
        try? await retentionIO { try FileManager.default.removeItem(at: root) }
        throw error
    }
}
#endif
