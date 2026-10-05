#if DEBUG && os(macOS)
import Foundation
import PincerKit

/// One actual ordinary/crashing child pair per invocation. An explicit test-only
/// override lets the root qualify the same controls with images=all separately.
@MainActor func runUnitNativeImageMappingChecks() async {
    do {
        let override = ProcessInfo.processInfo.environment["PINCER_NATIVE_IMAGE_MAPPING_BACKTRACE_OVERRIDE"]
        if let override {
            let expected = "enable=yes,interactive=no,color=no,timeout=0s,threads=crashed,registers=none,images=all,limit=32,symbolicate=fast,sanitize=yes,output-to=stderr"
            guard override == expected else {
                check(false, "image comparison override changes only images=mentioned to images=all")
                return
            }
        }
        let evidence = try await unitNativeBacktraceProof(
            backtraceOverrideForTesting: override, imageMappingControl: true)
        check(evidence.ordinaryPassed, "actual single native image-control child completes normally")
        guard evidence.ordinaryPassed else { print(evidence.diagnostics); return }
        check(evidence.crashOwnedStatus && evidence.crashBacktracePassed,
              "actual owned SIGSEGV retains native signal header and named fixture frame")
        guard evidence.crashOwnedStatus && evidence.crashBacktracePassed else {
            print(evidence.diagnostics)
            return
        }
        let mappings = evidence.imageMappings
        let qualified = mappings.count == 2 && mappings.map(\.mode) == ["ordinary", "crash"]
            && mappings.allSatisfy { mapping in
                guard mapping.markerValid,
                      let basename = mapping.targetBasename, !basename.isEmpty,
                      let uuid = mapping.targetUUID, uuid.count == 32,
                      uuid.allSatisfy({ $0.isHexDigit }),
                      let header = mapping.targetHeaderAddress, header > 0,
                      let reference = mapping.referenceBasename, !reference.isEmpty,
                      let referenceUUID = mapping.referenceUUID, referenceUUID.count == 32,
                      referenceUUID.allSatisfy({ $0.isHexDigit }) else { return false }
                return true
            }
        let identitiesAgree = qualified
            && mappings[0].targetBasename == mappings[1].targetBasename
            && mappings[0].targetUUID == mappings[1].targetUUID
            && mappings[0].referenceBasename == mappings[1].referenceBasename
            && mappings[0].referenceUUID == mappings[1].referenceUUID
        check(identitiesAgree, "actual native image markers contain valid UUID, basename and loaded header")
        guard identitiesAgree else { print(evidence.diagnostics); return }
        check(mappings[1].imagesTablePresent && mappings[1].referenceMappingPresent,
              "actual crash Images table contains the independently marked reference image")
        guard mappings[1].imagesTablePresent && mappings[1].referenceMappingPresent else {
            print(evidence.diagnostics)
            return
        }
        let scalarMappings = await Task.detached(priority: .utility) {
            String(decoding: (try? JSONEncoder().encode(mappings)) ?? Data(), as: UTF8.self)
        }.value
        print("Native image mapping controls: \(scalarMappings)")
        // Missing or malformed markers are setup failures, never the mapping regression.
        check(mappings[1].reportMappingPresent,
              "actual native crash report retains the independently marked image mapping: \(evidence.diagnostics)")
    } catch { check(false, "actual native image mapping setup: \(error)") }
}
#endif
